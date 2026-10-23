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
raw=$'sda|128035676160|Intenso SSD|usb|0|0|systemdisk\nsdb|33554432000|SanDisk|usb|1|0|\nsdc|0|Storage Device|usb|1|0|\nsdd|1073741824||usb|1|0|'
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
assert_equals "/dev/sdb" "$(printf '%s\n' "$choices" | sed -n 2p | cut -d'|' -f1)" "choices: fält 1 är sökväg"
assert_equals "33554432000" "$(printf '%s\n' "$choices" | sed -n 2p | cut -d'|' -f2)" "choices: fält 2 är storlek"
assert_equals "" "$(printf '%s\n' "$choices" | sed -n 2p | cut -d'|' -f3)" "choices: fält 3 är tom utan markör"
assert_equals "systemdisk" "$(printf '%s\n' "$choices" | sed -n 1p | cut -d'|' -f3)" "choices: fält 3 är markör"

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

# --- sammanfattning --------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
    echo -e "\033[32m✅ $tests tester, 0 misslyckanden\033[0m"
    exit 0
fi
echo -e "\033[31m❌ $tests tester, $failures misslyckanden\033[0m"
exit 1
