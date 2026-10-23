#!/bin/bash

# ---------------------------------------------------------------------------
# PXE-flash: skriver en PXE-först-U-Boot till ett microSD-kort i PXE-servern.
#
# Modulen är uppdelad i små funktioner med ett ansvar vardera. main_pxe_flash
# orchestrerar dem och innehåller ingen affärslogik.
#
#   pxe_flash_bootloaders_dir      hitta Bootloaders-katalogen i infra-repot
#   pxe_flash_require_host         kontrollera att servern är nåbar
#   pxe_flash_remote_devices       lista blockenheter på PXE-servern
#   pxe_flash_device_choices       rådata -> val-lista (fzf-rad per enhet)
#   pxe_flash_print_devices        visa enhetslistan
#   pxe_flash_select_device        välj kort + spärrar systemdisk/media
#   pxe_flash_select_board         välj datortyp
#   pxe_flash_board_image          datortyp -> U-Boot-image
#   pxe_flash_explain_no_image     förklara board utan bootloader-image
#   pxe_flash_verify_image         verifiera bilden innan flash
#   pxe_flash_confirm              bekräftelse
#   pxe_flash_unmount_partitions   avmontera partitioner på kortet
#   pxe_flash_copy_image           kopiera bilden till servern
#   pxe_flash_write_image          skriv bilden med dd
#   pxe_flash_cleanup              ta bort temporär fil på servern
#   pxe_flash_verify_written       jämför sha256 mellan källa och kort
#   pxe_flash_print_summary        slutrapport
# ---------------------------------------------------------------------------

# Rockchip-bootROM:en söker efter idbloader på sector 0x40 (byte 32768).
# Hela image-filen innehåller både loader1 och loader2, så skrivningen görs
# med seek=64. Se pxe/flash-uboot.sh i infrastructure-repot.
PXE_FLASH_SEEK=64
PXE_FLASH_REMOTE_DIR="/tmp/pxe-flash"

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
    awk -v bytes="${1:-0}" 'BEGIN {printf "%.1f", bytes/1073741824}'
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

# --- enhetslistning --------------------------------------------------------

# Blockenheter på servern, en rad per enhet:
#   name|size|model|tran|removable|hotplug|marker
pxe_flash_remote_devices() {
    ssh -o ConnectTimeout=5 "$1" -T 'sh -s' 2>/dev/null <<'REMOTE_SCRIPT'
root_src=$(findmnt -n -o SOURCE / 2>/dev/null)
root_disk=$(lsblk -ndo PKNAME "$root_src" 2>/dev/null | head -1)
lsblk -d -b -P -o NAME,SIZE,RM,HOTPLUG,TRAN,MODEL 2>/dev/null | while IFS= read -r line; do
    field() { printf '%s\n' "$line" | grep -o "$1=\"[^\"]*\"" | head -1 | sed "s/^$1=\"//;s/\"$//"; }
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

# Rådata -> en fzf-rad per enhet: path|size|marker|etikett
# Delimiter är "|" och inte tab: bash räknar tab som IFS-whitespace och
# skulle kollapsa tomma fält (t.ex. tom markör).
pxe_flash_device_choices() {
    local raw="$1"
    local name size model tran rm_flag hot marker size_gb flags label
    while IFS='|' read -r name size model tran rm_flag hot marker; do
        [ -z "$name" ] && continue
        size_gb=$(pxe_flash_bytes_to_gb "$size")
        flags=""
        [ "$rm_flag" = "1" ] && flags="${flags}removable "
        [ "$hot" = "1" ] && flags="${flags}hotplug "
        [ "$tran" = "usb" ] && flags="${flags}usb "
        [ "$marker" = "systemdisk" ] && flags="${flags}SYSTEMDISK "
        [ "${size:-0}" -eq 0 ] && flags="${flags}INGEN-MEDIA "
        label=$(printf '/dev/%-8s %8s GB  %-24s %s' "$name" "$size_gb" "${model:-okänd modell}" "$flags")
        printf '/dev/%s|%s|%s|%s\n' "$name" "$size" "$marker" "$label"
    done <<< "$raw"
}

pxe_flash_print_devices() {
    local choices
    choices=$(pxe_flash_device_choices "$1")
    [ -z "$choices" ] && return 0
    echo "Blockenheter:"
    printf '%s\n' "$choices" | cut -d'|' -f4 | sed 's/^/  /'
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

    selected=$(printf '%s\n' "$choices" | fzf --delimiter='|' --with-nth=4 \
        --prompt='SD-kort> ' --header="Välj microSD-kort i $host")
    if [ -z "$selected" ]; then
        echo "Avbrut."
        return 1
    fi

    IFS='|' read -r path size marker label <<< "$selected"

    if [ "$marker" = "systemdisk" ]; then
        pxe_flash_error "$path är serverns systemdisk - vill inte skriva U-Boot där"
        return 1
    fi
    if [ "${size:-0}" -eq 0 ]; then
        pxe_flash_error "Ingen media i $path - sätt i kortet och kör om"
        return 1
    fi

    printf '%s|%s|%s\n' "$path" "$size" "$marker"
}

# --- val och bekräftelse ---------------------------------------------------

pxe_flash_select_board() {
    local -a boards=(
        "Radxa Rock 4C+"
        "Radxa Rock 4SE"
        "Raspberry Pi 4"
    )
    local board
    board=$(printf '%s\n' "${boards[@]}" | fzf --prompt='Datortyp> ' \
        --header="Vilken dator ska kortet flashas för?")
    if [ -z "$board" ]; then
        echo "Avbrut."
        return 1
    fi
    printf '%s\n' "$board"
}

pxe_flash_explain_no_image() {
    local board="$1" bootloaders="$2"
    echo
    echo "$board har bootloader i ROM - inget skrivs till kortet."
    echo "För PXE-först sätts UEFI-bootordningen på noden med efibootmgr:"
    echo "  $bootloaders/Raspberry Pi 4/set-pxe-first.sh --apply"
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
    echo
    echo "Kort : $device"
    echo "Typ  : $board"
    echo "Bild : $image"
    echo
    echo "BootROM (RK3399) söker i ordningen: SPI-flash → eMMC → SD-kort → USB"
    echo "En giltig U-Boot i eMMC/SPI vinner över kortet."
    echo
    printf "Skriva U-Boot till %s? [nej/ja]: " "$device"
    local answer
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
    echo "Skriver till $device (seek=$PXE_FLASH_SEEK)..."
    ssh -t "$host" "sh -c 'sudo dd if=$PXE_FLASH_REMOTE_DIR/u-boot.bin of=$device bs=512 seek=$PXE_FLASH_SEEK conv=fsync status=progress'" || {
        pxe_flash_error "Skrivningen misslyckades"
        return 1
    }
}

pxe_flash_cleanup() {
    local host="$1"
    ssh -n -o ConnectTimeout=5 "$host" -T "sh -c 'rm -f $PXE_FLASH_REMOTE_DIR/u-boot.bin'" >/dev/null 2>&1
}

# Läser tillbaka det skrivna området och jämför mot källfilen.
pxe_flash_verify_written() {
    local host="$1" device="$2" image="$3"
    local sectors local_sha remote_sha

    echo "Verifierar..."
    sectors=$(( ($(stat -c%s "$image") + 511) / 512 ))
    local_sha=$(sha256sum "$image" | cut -d' ' -f1)
    remote_sha=$(ssh -o ConnectTimeout=5 "$host" -T 'sh -s' <<REMOTE_SCRIPT
sudo dd if=$device bs=512 skip=$PXE_FLASH_SEEK count=$sectors status=none | sha256sum | cut -d' ' -f1
REMOTE_SCRIPT
)
    remote_sha=$(printf '%s' "$remote_sha" | tr -d '[:space:]')

    if [ "$local_sha" != "$remote_sha" ]; then
        pxe_flash_error "Verifieringen misslyckades"
        echo "  lokal : $local_sha" >&2
        echo "  server: $remote_sha" >&2
        return 1
    fi

    pxe_flash_ok "$device är byte-identisk med källan"
    echo "  sha256: $local_sha"
}

pxe_flash_print_summary() {
    echo
    echo "Nästa steg: sätt kortet i noden och starta den."
    echo "U-Boot försöker nätverksboot (PXE) först via boot_script_dhcp=talos/bsc."
}

# --- orchestration ----------------------------------------------------------

main_pxe_flash() {
    local host="${PXE_HOST:-pxe}"
    local bootloaders raw record device board image

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
    IFS='|' read -r device _ _ <<< "$record"

    board=$(pxe_flash_select_board) || return 1

    if ! image=$(pxe_flash_board_image "$bootloaders" "$board"); then
        pxe_flash_explain_no_image "$board" "$bootloaders"
        return 0
    fi

    pxe_flash_verify_image "$bootloaders" "$image" || return 1
    pxe_flash_confirm "$device" "$board" "$image" || return 1

    pxe_flash_unmount_partitions "$host" "$device"
    pxe_flash_copy_image "$host" "$image" || return 1

    pxe_flash_write_image "$host" "$device"
    local write_status=$?
    pxe_flash_cleanup "$host"
    [ "$write_status" -eq 0 ] || return 1

    pxe_flash_verify_written "$host" "$device" "$image" || return 1

    pxe_flash_print_summary
}
