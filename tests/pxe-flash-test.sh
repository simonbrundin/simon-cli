#!/bin/bash

# Tester för de rena funktionerna i scripts/pxe-flash.sh.
# Kör: ./tests/pxe-flash-test.sh
#
# Funktionerna som kräver ssh/scp/dd testas inte här - de verifieras genom
# att köra "simon pxe flash" mot en riktig kortläsare i PXE-servern.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../scripts/pxe-flash.sh"

failures=0
tests=0

assert_equals() {
    local expected="$1" actual="$2" description="$3"
    tests=$((tests + 1))
    if [ "$expected" != "$actual" ]; then
        failures=$((failures + 1))
        echo "❌ $description"
        echo "   förväntat: '$expected'"
        echo "   fick:     '$actual'"
        return 1
    fi
}

assert_contains() {
    local haystack="$1" needle="$2" description="$3"
    tests=$((tests + 1))
    if ! printf '%s' "$haystack" | grep -qF -- "$needle"; then
        failures=$((failures + 1))
        echo "❌ $description"
        echo "   saknade: '$needle'"
        echo "   fick:    '$haystack'"
        return 1
    fi
}

assert_not_contains() {
    local haystack="$1" needle="$2" description="$3"
    tests=$((tests + 1))
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        failures=$((failures + 1))
        echo "❌ $description"
        echo "   hade oväntat: '$needle'"
        return 1
    fi
}

assert_fails() {
    local description="$1"
    shift
    tests=$((tests + 1))
    if "$@" >/dev/null 2>&1; then
        failures=$((failures + 1))
        echo "❌ $description (borde ha misslyckats)"
        return 1
    fi
}

# --- pxe_flash_bytes_to_gb -------------------------------------------------
assert_equals "1.0" "$(pxe_flash_bytes_to_gb 1073741824)" "bytes_to_gb: 1 GiB"
assert_equals "0.0" "$(pxe_flash_bytes_to_gb 0)" "bytes_to_gb: noll"
assert_equals "31.2" "$(pxe_flash_bytes_to_gb 33554432000)" "bytes_to_gb: 31.2 GB"
assert_equals "0.0" "$(pxe_flash_bytes_to_gb)" "bytes_to_gb: tomt argument"

# --- pxe_flash_device_choices ----------------------------------------------
# Fält n på rad n i en lista av pipe-kodade rader.
choice_field() {
    printf '%s\n' "$1" | sed -n "$2p" | cut -d'|' -f"$3"
}

raw=""
raw+="sda|128035676160|Intenso SSD|usb|0|0|systemdisk"$'\n'
raw+="sdb|33554432000|SanDisk|usb|1|0|"$'\n'
raw+="sdc|0|Storage Device|usb|1|0|"$'\n'
raw+="sdd|1073741824||usb|1|0|"
choices=$(pxe_flash_device_choices "$raw")

assert_contains "$choices" "/dev/sda" "choices: sda finns"
assert_contains "$choices" "/dev/sdb" "choices: sdb finns"
assert_contains "$choices" "31.2 GB" "choices: storlek formateras"
assert_contains "$choices" "removable" "choices: removable-flagga"
assert_contains "$choices" "SYSTEMDISK" "choices: systemdisken märks"
assert_contains "$choices" "INGEN-MEDIA" "choices: tomt kort märks"
assert_contains "$choices" "okänd modell" "choices: tom modell får platshållare"
assert_equals "4" "$(printf '%s\n' "$choices" | wc -l)" "choices: en rad per enhet"

# Etiketten ligger i fjärde fältet, metadatan i de tre första.
assert_equals "/dev/sdb" "$(choice_field "$choices" 2 1)" "choices: fält 1 är sökväg"
assert_equals "33554432000" "$(choice_field "$choices" 2 2)" "choices: fält 2 är storlek"
assert_equals "" "$(choice_field "$choices" 2 3)" "choices: fält 3 är tom utan markör"
assert_equals "systemdisk" "$(choice_field "$choices" 1 3)" "choices: fält 3 är markör"

# Loop- och ram-enheter filtreras bort redan i uppslagssteget på servern,
# men tomma rader ska ändå ignoreras.
assert_equals "0" "$(pxe_flash_device_choices '' | wc -l)" "choices: tom inmatning ger inga rader"

# --- pxe_flash_select_device (guardar) -------------------------------------
# fzf stubbas för att kunna testa valet utan interaktion.
fzf() { printf '%s\n' "$FZF_STUB_RESULT"; }

FZF_STUB_RESULT='/dev/sdb|33554432000||/dev/sdb 31.2 GB SanDisk'
assert_equals '/dev/sdb|33554432000|' \
    "$(pxe_flash_select_device "pxe" "$raw" 2>/dev/null)" "select_device: returnerar vald enhet"

FZF_STUB_RESULT='/dev/sda|128035676160|systemdisk|/dev/sda 119.2 GB Intenso SSD SYSTEMDISK'
assert_fails "select_device: vägrar systemdisken" \
    pxe_flash_select_device "pxe" "$raw"

FZF_STUB_RESULT='/dev/sdc|0||/dev/sdc 0.0 GB Storage Device INGEN-MEDIA'
assert_fails "select_device: vägrar kort utan media" \
    pxe_flash_select_device "pxe" "$raw"

# --- pxe_flash_board_image -------------------------------------------------
bootloaders="/tmp/infra/pxe/Bootloaders"
assert_equals "$bootloaders/Radxa Rock 4C+/u-boot-rockchip-pxe-first.bin" \
    "$(pxe_flash_board_image "$bootloaders" "Radxa Rock 4C+")" "board_image: Rock 4C+"
assert_equals "$bootloaders/Radxa Rock 4SE/u-boot-rockchip-pxe-first.bin" \
    "$(pxe_flash_board_image "$bootloaders" "Radxa Rock 4SE")" "board_image: Rock 4SE"
assert_fails "board_image: Raspberry Pi 4 har ingen image" \
    pxe_flash_board_image "$bootloaders" "Raspberry Pi 4"
assert_fails "board_image: okänd board" \
    pxe_flash_board_image "$bootloaders" "Något annat"

# --- pxe_flash_bootloaders_dir ---------------------------------------------
tmp_repo=$(mktemp -d)
mkdir -p "$tmp_repo/pxe/Bootloaders"
assert_equals "$tmp_repo/pxe/Bootloaders" \
    "$(INFRA_REPO="$tmp_repo" pxe_flash_bootloaders_dir)" "bootloaders_dir: hittar INFRA_REPO"

INFRA_REPO="/tmp/saknas-här" pxe_flash_bootloaders_dir >/dev/null 2>&1
if [ $? -eq 0 ] && [ -d "$HOME/infrastructure/pxe/Bootloaders" ]; then
    echo "ℹ️  bootloaders_dir: faller tillbaka på \$HOME/infrastructure"
fi
rm -rf "$tmp_repo"

# --- fälthantering ---------------------------------------------------------
assert_equals "b" "$(pxe_flash_field 'a|b|c' 2)" "field: fält 2"
assert_equals "c" "$(pxe_flash_field 'a|b|c' 3)" "field: fält 3"
assert_equals "a|b|c" "$(pxe_flash_join_fields a b c)" "join_fields: sätter ihop fält"
assert_equals "a||c" "$(pxe_flash_join_fields a "" c)" "join_fields: tomt fält behålls"

# --- pxe_flash_device_flags -------------------------------------------------
assert_contains "$(pxe_flash_device_flags usb 1 0 '' 100)" "removable" "device_flags: removable"
assert_contains "$(pxe_flash_device_flags usb 1 0 '' 100)" "usb" "device_flags: usb"
flags=$(pxe_flash_device_flags usb 0 0 systemdisk 100)
assert_contains "$flags" "SYSTEMDISK" "device_flags: systemdisk"
assert_contains "$(pxe_flash_device_flags usb 1 0 '' 0)" "INGEN-MEDIA" "device_flags: ingen media"
flags=$(pxe_flash_device_flags '' 0 0 '' 100)
assert_not_contains "$flags" "removable" "device_flags: inga flaggor"

# --- pxe_flash_device_label -------------------------------------------------
label=$(pxe_flash_device_label sdb 33554432000 SanDisk 'usb ')
assert_contains "$label" "31.2 GB" "device_label: storlek"
label=$(pxe_flash_device_label sdb 0 '' '')
assert_contains "$label" "okänd modell" "device_label: modellplatshållare"
assert_contains "$(pxe_flash_device_label sdb 100 '' '')" "/dev/sdb" "device_label: sökväg"

# --- pxe_flash_board_manual_hint -------------------------------------------
assert_equals "$bootloaders/Raspberry Pi 4/set-pxe-first.sh --apply" \
    "$(pxe_flash_board_manual_hint "$bootloaders" "Raspberry Pi 4")" "manual_hint: Pi4"
assert_fails "manual_hint: Rock 4C+ har ingen manuell åtgärd" \
    pxe_flash_board_manual_hint "$bootloaders" "Radxa Rock 4C+"

# --- pxe_flash_sectors_for_file --------------------------------------------
tmp_file=$(mktemp)
printf 'x' > "$tmp_file"
assert_equals "1" "$(pxe_flash_sectors_for_file "$tmp_file")" "sectors_for_file: 1 byte -> 1 sektor"
printf '%1024s' '' > "$tmp_file"
sectors=$(pxe_flash_sectors_for_file "$tmp_file")
assert_equals "2" "$sectors" "sectors_for_file: 1024 byte -> 2 sektorer"
rm -f "$tmp_file"

# --- pxe_flash_compare_sha --------------------------------------------------
assert_equals "0" \
    "$(pxe_flash_compare_sha /dev/sdb abc123 abc123 >/dev/null 2>&1; echo $?)" \
    "compare_sha: lika hash godkänns"
assert_equals "1" \
    "$(pxe_flash_compare_sha /dev/sdb abc123 def456 >/dev/null 2>&1; echo $?)" \
    "compare_sha: olika hash avvisas"

# --- pxe_flash_wipe_script -------------------------------------------------
# Nollställningen körs på servern, men själva scriptet är ren text och
# kan därför testas här.
wipe_script=$(pxe_flash_wipe_script /dev/sdb)
assert_contains "$wipe_script" 'dev="/dev/sdb"' "wipe_script: använder rätt enhet"
assert_contains "$wipe_script" "sgdisk --zap-all" "wipe_script: raderar partitionstabellen"
assert_contains "$wipe_script" "wipefs -a" "wipe_script: raderar filesystem-signaturer"
assert_contains "$wipe_script" "if=/dev/zero" "wipe_script: nollställer med dd"
assert_contains "$wipe_script" "blockdev --getsize64" "wipe_script: läser enhetens storlek"
assert_contains "$wipe_script" "seek=\$(( mb - wipe_mb ))" \
    "wipe_script: nollställer slutet av kortet"
assert_contains "$wipe_script" "count=\$wipe_mb" \
    "wipe_script: nollställer $PXE_FLASH_WIPE_MB MB i början"
assert_contains "$wipe_script" "wipe_mb=$PXE_FLASH_WIPE_MB" \
    "wipe_script: wipe_mb definieras i fjärrscriptet"

# Enheten ska alltid sättas i variabeln dev - inte hårdkodas på flera ställen.
assert_equals "1" \
    "$(printf '%s' "$wipe_script" | grep -c '/dev/sdb')" \
    "wipe_script: enheten nämns bara i definitionen av dev"
assert_not_contains "$wipe_script" 'of=/dev/sdb' \
    "wipe_script: dd skriver via \$dev, inte hårdkodat"

# --- sammanfattning --------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
    echo -e "\033[32m✅ $tests tester, 0 misslyckanden\033[0m"
    exit 0
fi
echo -e "\033[31m❌ $tests tester, $failures misslyckanden\033[0m"
exit 1
