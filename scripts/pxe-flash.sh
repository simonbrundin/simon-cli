#!/bin/bash

# ---------------------------------------------------------------------------
# PXE-flash: skriver en PXE-först-U-Boot till ett microSD-kort i PXE-servern.
#
# Modulen är uppdelad i små funktioner med ett ansvar vardera. main_pxe_flash
# orchestrerar dem och innehåller ingen affärslogik.
#
#   pxe_flash_error/ok/info          presentationshjälpare
#   pxe_flash_bytes_to_gb            formatering av storlek
#   pxe_flash_field/join_fields      läs och skriv pipe-delimited fält
#   pxe_flash_select_with_fzf        gemensam fzf-hjälpare
#   pxe_flash_bootloaders_dir        hitta Bootloaders-katalogen i infra-repot
#   pxe_flash_board_image            datortyp -> U-Boot-image
#   pxe_flash_board_manual_hint      datortyp -> manuell åtgärd
#   pxe_flash_remote_devices         lista blockenheter på PXE-servern
#   pxe_flash_device_flags           flaggor för en enhet
#   pxe_flash_device_label           etikett för en enhet
#   pxe_flash_device_choices         rådata -> val-lista (fzf-rad per enhet)
#   pxe_flash_print_devices          visa enhetslistan
#   pxe_flash_choose_device          välj kort i fzf
#   pxe_flash_assert_device_is_safe  spärrar systemdisk och tom media
#   pxe_flash_select_device          välj + spärr
#   pxe_flash_select_board           välj datortyp
#   pxe_flash_explain_no_image       förklara board utan bootloader-image
#   pxe_flash_verify_image           verifiera bilden innan flash
#   pxe_flash_confirm                bekräftelse
#   pxe_flash_require_host           kontrollera att servern är nåbar
#   pxe_flash_unmount_partitions     avmontera partitioner på kortet
#   pxe_flash_wipe_script            fjärrscript som nollställer kortet
#   pxe_flash_wipe_partitions        nollställ partitionstabel och artefakter
#   pxe_flash_copy_image             kopiera bilden till servern
#   pxe_flash_write_image            skriv bilden med dd
#   pxe_flash_cleanup                ta bort temporär fil på servern
#   pxe_flash_sectors_for_file       filstorlek -> antal sektorer
#   pxe_flash_remote_sha             sha256 av det skrivna området
#   pxe_flash_compare_sha            jämför och rapportera
#   pxe_flash_verify_written         verifiera det skrivna kortet
#   pxe_flash_print_summary          slutrapport
# ---------------------------------------------------------------------------

# Rockchip-bootROM:en söker efter idbloader på sector 0x40 (byte 32768).
# Hela image-filen innehåller både loader1 och loader2, så skrivningen görs
# med seek=64. Se pxe/flash-uboot.sh i infrastructure-repot.
PXE_FLASH_SEEK=64
PXE_FLASH_SECTOR_SIZE=512
PXE_FLASH_BYTES_PER_GB=1073741824
PXE_FLASH_REMOTE_DIR="/tmp/pxe-flash"

# Antal MB som nollställs i början och slutet av kortet. 8 MB räcker för
# GPT-headern, backup-GPT och de första utrymmena för gamla bootloaders.
PXE_FLASH_WIPE_MB=8
PXE_FLASH_BYTES_PER_MB=1048576

# Delimiter mellan fält i de pipe-kodade raderna. Inte tab: bash räknar tab
# som IFS-whitespace och skulle kollapsa tomma fält (t.ex. tom markör).
PXE_FLASH_FIELD_SEP="|"

# --- presentationshjälpare -------------------------------------------------

pxe_flash_error() {
    echo -e "\033[31m❌ $*\033[0m" >&2
}

pxe_flash_ok() {
    echo -e "\033[32m✅ $*\033[0m"
}

pxe_flash_info() {
    echo -e "\033[34m$*\033[0m"
}

pxe_flash_bytes_to_gb() {
    awk -v bytes="${1:-0}" -v per_gb="$PXE_FLASH_BYTES_PER_GB" \
        'BEGIN {printf "%.1f", bytes/per_gb}'
}

# --- fälthantering ---------------------------------------------------------

# Fält n (1-baserat) ur en pipe-kodad rad.
pxe_flash_field() {
    printf '%s' "$1" | cut -d"$PXE_FLASH_FIELD_SEP" -f"$2"
}

# Sätter ihop fält till en pipe-kodad rad.
pxe_flash_join_fields() {
    local out="" value
    for value in "$@"; do
        out="${out:+$out$PXE_FLASH_FIELD_SEP}$value"
    done
    printf '%s' "$out"
}

# Gemensam fzf-hjälpare. $4 är fältet som visas (tomt = hela raden).
pxe_flash_select_with_fzf() {
    local list="$1" prompt="$2" header="$3" visible_field="$4"
    local selected

    if [ -n "$visible_field" ]; then
        selected=$(printf '%s\n' "$list" | fzf --delimiter="$PXE_FLASH_FIELD_SEP" \
            --with-nth="$visible_field" --prompt="$prompt" --header="$header")
    else
        selected=$(printf '%s\n' "$list" | fzf --prompt="$prompt" --header="$header")
    fi

    if [ -z "$selected" ]; then
        echo "Avbrut."
        return 1
    fi
    printf '%s\n' "$selected"
}

# --- uppslag ---------------------------------------------------------------

# Sökväg till Bootloaders-katalogen. INFRA_REPO vinner, annars $HOME/infrastructure.
pxe_flash_bootloaders_dir() {
    local candidate
    for candidate in "${INFRA_REPO:-$HOME/repos/infrastructure}" "$HOME/infrastructure"; do
        if [ -d "$candidate/pxe/Bootloaders" ]; then
            printf '%s\n' "$candidate/pxe/Bootloaders"
            return 0
        fi
    done
    return 1
}

# U-Boot-image för en datortyp. Returnerar 1 för boardar utan image
# (t.ex. Raspberry Pi 4, som har bootloader i ROM).
pxe_flash_board_image() {
    local bootloaders="$1" board="$2"
    case "$board" in
        "Radxa Rock 4C+")
            printf '%s\n' "$bootloaders/Radxa Rock 4C+/u-boot-rockchip-pxe-first.bin"
            ;;
        "Radxa Rock 4SE")
            printf '%s\n' "$bootloaders/Radxa Rock 4SE/u-boot-rockchip-pxe-first.bin"
            ;;
        *)
            return 1
            ;;
    esac
}

# Manuell åtgärd för boardar som inte kan flashas. Returnerar 1 om ingen finns.
pxe_flash_board_manual_hint() {
    local bootloaders="$1" board="$2"
    case "$board" in
        "Raspberry Pi 4")
            printf '%s\n' "$bootloaders/Raspberry Pi 4/set-pxe-first.sh --apply"
            ;;
        *)
            return 1
            ;;
    esac
}

# --- enhetslistning --------------------------------------------------------

# Blockenheter på servern, en rad per enhet:
#   name|size|model|tran|removable|hotplug|marker
pxe_flash_remote_devices() {
    ssh -o ConnectTimeout=5 "$1" -T 'sh -s' 2>/dev/null <<'REMOTE_SCRIPT'
root_src=$(findmnt -n -o SOURCE / 2>/dev/null)
root_disk=$(lsblk -ndo PKNAME "$root_src" 2>/dev/null | head -1)
lsblk -d -b -P -o NAME,SIZE,RM,HOTPLUG,TRAN,MODEL 2>/dev/null | while IFS= read -r line; do
    field() { printf '%s\n' "$line" | grep -o "$1=\"[^\"]*\"" | head -1 \
        | sed "s/^$1=\"//;s/\"$//"; }
    name=$(field NAME)
    size=$(field SIZE)
    case "$name" in
        loop*|ram*|zram*|sr*|fd*) continue ;;
    esac
    rm_flag=$(field RM)
    hot=$(field HOTPLUG)
    tran=$(field TRAN)
    model=$(field MODEL)
    marker=""
    [ "$name" = "$root_disk" ] && marker="systemdisk"
    printf '%s|%s|%s|%s|%s|%s|%s\n' "$name" "$size" "$model" "$tran" "$rm_flag" "$hot" "$marker"
done
REMOTE_SCRIPT
}

# Flaggor som beskriver en enhet för listan.
pxe_flash_device_flags() {
    local tran="$1" rm_flag="$2" hot="$3" marker="$4" size="$5"
    local flags=""
    [ "$rm_flag" = "1" ] && flags="${flags}removable "
    [ "$hot" = "1" ] && flags="${flags}hotplug "
    [ "$tran" = "usb" ] && flags="${flags}usb "
    [ "$marker" = "systemdisk" ] && flags="${flags}SYSTEMDISK "
    [ "${size:-0}" -eq 0 ] && flags="${flags}INGEN-MEDIA "
    printf '%s' "$flags"
}

# Etikett som visas i listan och i fzf.
pxe_flash_device_label() {
    local name="$1" size="$2" model="$3" flags="$4"
    printf '/dev/%-8s %8s GB  %-24s %s' \
        "$name" "$(pxe_flash_bytes_to_gb "$size")" "${model:-okänd modell}" "$flags"
}

# Rådata -> en fzf-rad per enhet: path|size|marker|etikett
pxe_flash_device_choices() {
    local raw="$1"
    local name size model tran rm_flag hot marker flags label
    while IFS='|' read -r name size model tran rm_flag hot marker; do
        [ -z "$name" ] && continue
        flags=$(pxe_flash_device_flags "$tran" "$rm_flag" "$hot" "$marker" "$size")
        label=$(pxe_flash_device_label "$name" "$size" "$model" "$flags")
        pxe_flash_join_fields "/dev/$name" "$size" "$marker" "$label"
        echo
    done <<< "$raw"
}

pxe_flash_print_devices() {
    local choices
    choices=$(pxe_flash_device_choices "$1")
    [ -z "$choices" ] && return 0
    echo "Blockenheter:"
    printf '%s\n' "$choices" | while IFS='|' read -r _ _ _ label; do
        echo "  $label"
    done
}

# Väljer ett kort i fzf. Returnerar den valda raden.
pxe_flash_choose_device() {
    local host="$1" choices="$2"
    pxe_flash_select_with_fzf "$choices" 'SD-kort> ' "Välj microSD-kort i $host" 4
}

# Spärrar som gör att vi aldrig skriver till fel enhet.
pxe_flash_assert_device_is_safe() {
    local path="$1" size="$2" marker="$3"

    if [ "$marker" = "systemdisk" ]; then
        pxe_flash_error "$path är serverns systemdisk - vill inte skriva U-Boot där"
        return 1
    fi
    if [ "${size:-0}" -eq 0 ]; then
        pxe_flash_error "Ingen media i $path - sätt i kortet och kör om"
        return 1
    fi
}

# Väljer ett kort. Skriver ut "path|size|marker" för valet.
pxe_flash_select_device() {
    local host="$1" raw="$2"
    local choices selected path size marker label

    choices=$(pxe_flash_device_choices "$raw")
    if [ -z "$choices" ]; then
        pxe_flash_error "Inga blockenheter hittades på $host"
        return 1
    fi

    selected=$(pxe_flash_choose_device "$host" "$choices") || return 1
    IFS='|' read -r path size marker label <<< "$selected"

    pxe_flash_assert_device_is_safe "$path" "$size" "$marker" || return 1

    pxe_flash_join_fields "$path" "$size" "$marker"
    echo
}

# --- val och bekräftelse ---------------------------------------------------

pxe_flash_select_board() {
    local -a boards=(
        "Radxa Rock 4C+"
        "Radxa Rock 4SE"
        "Raspberry Pi 4"
    )
    pxe_flash_select_with_fzf "$(printf '%s\n' "${boards[@]}")" 'Datortyp> ' \
        "Vilken dator ska kortet flashas för?" ""
}

pxe_flash_explain_no_image() {
    local board="$1" bootloaders="$2"
    local hint

    echo
    echo "$board har bootloader i ROM - inget skrivs till kortet."
    if hint=$(pxe_flash_board_manual_hint "$bootloaders" "$board"); then
        echo "För PXE-först sätts UEFI-bootordningen på noden med efibootmgr:"
        echo "  $hint"
    fi
}

pxe_flash_verify_image() {
    local bootloaders="$1" image="$2"

    if [ ! -f "$image" ]; then
        pxe_flash_error "Bilden saknas: $image"
        echo "Bygg den med pxe/Bootloaders/build-mainline-uboot.sh" >&2
        return 1
    fi
    if [ -x "$bootloaders/verify-uboot-image.sh" ]; then
        echo
        "$bootloaders/verify-uboot-image.sh" "$image" || {
            pxe_flash_error "Bilden klarade inte verifieringen - avbryter"
            return 1
        }
    fi
}

pxe_flash_confirm() {
    local device="$1" board="$2" image="$3"
    local answer

    echo
    echo "Kort : $device"
    echo "Typ  : $board"
    echo "Bild : $image"
    echo
    echo "BootROM (RK3399) söker i ordningen: SPI-flash → eMMC → SD-kort → USB"
    echo "En giltig U-Boot i eMMC/SPI vinner över kortet."
    echo
    echo "Kortet nollställs först: partitionstabellen och all annan data raderas,"
    echo "så att bara U-Boot finns kvar att boota från."
    echo
    printf "Skriva U-Boot till %s? [nej/ja]: " "$device"
    read -r answer
    if [ "$answer" != "ja" ]; then
        echo "Avbrut."
        return 1
    fi
}

# --- fjärråtgärder mot PXE-servern ----------------------------------------

pxe_flash_require_host() {
    if ! ssh -n -o ConnectTimeout=5 "$1" -T 'sh -c "echo ok"' >/dev/null 2>&1; then
        pxe_flash_error "Kunde inte nå PXE-servern ($1)"
        return 1
    fi
}

pxe_flash_unmount_partitions() {
    local host="$1" device="$2"
    ssh -o ConnectTimeout=5 "$host" -T 'sh -s' <<REMOTE_SCRIPT
lsblk -lnpo NAME,TYPE $device 2>/dev/null | while read -r pname ptype; do
    if [ "\$ptype" = "part" ]; then
        if findmnt -n --source "\$pname" >/dev/null 2>&1; then
            echo "Avmonterar \$pname"
            sudo umount "\$pname" 2>/dev/null || true
        fi
    fi
done
REMOTE_SCRIPT
}

# Fjärrscript som nollställer kortet före skrivning.
#
# Varför: bara skriva U-Boot-image över ett befintligt kort lämnar den
# gamla partitionstabellen och en EFI-partition kvar. Då kan U-Boot hitta
# en gammal bootloader (t.ex. en installerad Talos) och starta den i stället
# för vår PXE-image. Rätt sista kort ska bara innehålla U-Boot.
#
# Returneras som text så att innehållet kan testas utan att röra en disk.
pxe_flash_wipe_script() {
    local device="$1"
    local wipe_mb="$PXE_FLASH_WIPE_MB"

    cat <<EOF
set -e
dev="$device"
wipe_mb=$PXE_FLASH_WIPE_MB

# 1. Partitionstabell (GPT/MBR). sgdisk nollställer även backup-GPT.
if command -v sgdisk >/dev/null 2>&1; then
    sudo sgdisk --zap-all "\$dev" || true
fi

# 2. Filesystem-signaturer.
sudo wipefs -a "\$dev" || true

# 3. Början och slutet: gamla bootloaders, GPT-artefakter, restdata.
size=\$(sudo blockdev --getsize64 "\$dev")
mb=\$(( size / $PXE_FLASH_BYTES_PER_MB ))
sudo dd if=/dev/zero of="\$dev" bs=$PXE_FLASH_BYTES_PER_MB count=\$wipe_mb conv=fsync status=none
if [ "\$mb" -gt \$(( wipe_mb * 2 )) ]; then
    sudo dd if=/dev/zero of="\$dev" bs=$PXE_FLASH_BYTES_PER_MB \\
        seek=\$(( mb - wipe_mb )) count=\$wipe_mb conv=fsync status=none
fi
sync
EOF
}

# Nollställer kortet på PXE-servern.
pxe_flash_wipe_partitions() {
    local host="$1" device="$2"

    echo "Nollställer partitionstabell och gamla artefakter på $device..."
    ssh -o ConnectTimeout=5 "$host" -T 'sh -s' <<REMOTE_SCRIPT
$(pxe_flash_wipe_script "$device")
REMOTE_SCRIPT
}

pxe_flash_copy_image() {
    local host="$1" image="$2"

    echo "Kopierar bilden till $host..."
    ssh -n -o ConnectTimeout=5 "$host" -T "sh -c 'mkdir -p $PXE_FLASH_REMOTE_DIR'" || return 1
    scp -q "$image" "$host:$PXE_FLASH_REMOTE_DIR/u-boot.bin" || {
        pxe_flash_error "Kunde inte kopiera bilden"
        return 1
    }
}

pxe_flash_write_image() {
    local host="$1" device="$2"
    local remote_cmd

    echo "Skriver till $device (seek=$PXE_FLASH_SEEK)..."
    remote_cmd="sudo dd if=$PXE_FLASH_REMOTE_DIR/u-boot.bin of=$device"
    remote_cmd="$remote_cmd bs=$PXE_FLASH_SECTOR_SIZE seek=$PXE_FLASH_SEEK"
    remote_cmd="$remote_cmd conv=fsync status=progress"
    ssh -t "$host" "sh -c '$remote_cmd'" || {
        pxe_flash_error "Skrivningen misslyckades"
        return 1
    }
}

pxe_flash_cleanup() {
    local host="$1"
    ssh -n -o ConnectTimeout=5 "$host" -T \
        "sh -c 'rm -f $PXE_FLASH_REMOTE_DIR/u-boot.bin'" >/dev/null 2>&1
}

# --- verifiering av det skrivna kortet -------------------------------------

# Antal sektorer som en fil täcker (avrundat uppåt).
pxe_flash_sectors_for_file() {
    local bytes
    bytes=$(stat -c%s "$1")
    echo $(( (bytes + PXE_FLASH_SECTOR_SIZE - 1) / PXE_FLASH_SECTOR_SIZE ))
}

# sha256 av det område som skrivdes på kortet.
pxe_flash_remote_sha() {
    local host="$1" device="$2" sectors="$3"
    local sha

    sha=$(ssh -o ConnectTimeout=5 "$host" -T 'sh -s' <<REMOTE_SCRIPT
sudo dd if=$device bs=$PXE_FLASH_SECTOR_SIZE skip=$PXE_FLASH_SEEK count=$sectors status=none \
    | sha256sum | cut -d' ' -f1
REMOTE_SCRIPT
)
    printf '%s' "$sha" | tr -d '[:space:]'
}

# Jämför och rapporterar.
pxe_flash_compare_sha() {
    local device="$1" local_sha="$2" remote_sha="$3"

    if [ "$local_sha" != "$remote_sha" ]; then
        pxe_flash_error "Verifieringen misslyckades"
        echo "  lokal : $local_sha" >&2
        echo "  server: $remote_sha" >&2
        return 1
    fi

    pxe_flash_ok "$device är byte-identisk med källan"
    echo "  sha256: $local_sha"
}

pxe_flash_verify_written() {
    local host="$1" device="$2" image="$3"
    local sectors local_sha remote_sha

    echo "Verifierar..."
    sectors=$(pxe_flash_sectors_for_file "$image")
    local_sha=$(sha256sum "$image" | cut -d' ' -f1)
    remote_sha=$(pxe_flash_remote_sha "$host" "$device" "$sectors")

    pxe_flash_compare_sha "$device" "$local_sha" "$remote_sha"
}

pxe_flash_print_summary() {
    echo
    echo "Nästa steg: sätt kortet i noden och starta den."
    echo "U-Boot försöker nätverksboot (PXE) först via boot_script_dhcp=talos/bsc."
    echo "Kortet är nollställt - det innehåller bara U-Boot, ingen partitionstabell."
}

# --- orchestration ----------------------------------------------------------

main_pxe_flash() {
    local host="${PXE_HOST:-pxe}"
    local bootloaders raw record device board image write_status

    pxe_flash_info "=== Flasha PXE-först-kort ==="
    echo "Server: $host"
    echo

    bootloaders=$(pxe_flash_bootloaders_dir) || {
        pxe_flash_error "Hittade inte infrastructure-repot (sätt INFRA_REPO=/sökväg)"
        return 1
    }

    pxe_flash_require_host "$host" || return 1

    raw=$(pxe_flash_remote_devices "$host")
    if [ -z "$raw" ]; then
        pxe_flash_error "Kunde inte lista blockenheter på $host"
        return 1
    fi

    pxe_flash_print_devices "$raw"

    record=$(pxe_flash_select_device "$host" "$raw") || return 1
    device=$(pxe_flash_field "$record" 1)

    board=$(pxe_flash_select_board) || return 1

    if ! image=$(pxe_flash_board_image "$bootloaders" "$board"); then
        pxe_flash_explain_no_image "$board" "$bootloaders"
        return 0
    fi

    pxe_flash_verify_image "$bootloaders" "$image" || return 1
    pxe_flash_confirm "$device" "$board" "$image" || return 1

    pxe_flash_unmount_partitions "$host" "$device"
    pxe_flash_wipe_partitions "$host" "$device" || return 1
    pxe_flash_copy_image "$host" "$image" || return 1

    pxe_flash_write_image "$host" "$device"
    write_status=$?
    pxe_flash_cleanup "$host"
    [ "$write_status" -eq 0 ] || return 1

    pxe_flash_verify_written "$host" "$device" "$image" || return 1

    pxe_flash_print_summary
}
