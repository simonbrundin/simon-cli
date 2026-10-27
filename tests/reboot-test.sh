#!/bin/bash

# Tester för de rena funktionerna i scripts/reboot.sh.
# Kör: ./tests/reboot-test.sh
#
# Funktionerna som kräver en levande nod (talosctl reboot) testas inte här -
# de verifieras genom att köra "simon reboot controlplane-1" mot en riktig nod.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../scripts/talos.sh"
source "$here/../scripts/reboot.sh"

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

assert_fails() {
    local description="$1"
    shift
    tests=$((tests + 1))
    if "$@" >/dev/null 2>&1; then
        failures=$((failures + 1))
        echo "❌ $description"
        echo "   förväntade felstatus, men kommandot lyckades"
        return 1
    fi
}

# --- is_ip ------------------------------------------------------------------
assert_equals "0" "$(reboot_is_ip 10.10.10.11 && echo 0 || echo 1)" \
    "is_ip: IPv4-adress godkänns"
assert_equals "1" "$(reboot_is_ip controlplane-1 >/dev/null 2>&1 && echo 0 || echo 1)" \
    "is_ip: nodnamn är inte en IP"
assert_equals "1" "$(reboot_is_ip '' >/dev/null 2>&1 && echo 0 || echo 1)" \
    "is_ip: tom sträng är inte en IP"

# --- parse_args -------------------------------------------------------------
assert_equals "controlplane-1|" \
    "$(reboot_parse_args controlplane-1)" \
    "parse_args: mål utan flaggor"
assert_equals "controlplane-1|--drain" \
    "$(reboot_parse_args controlplane-1 --drain)" \
    "parse_args: mål med en flagga"
assert_equals "controlplane-1|--drain --force" \
    "$(reboot_parse_args controlplane-1 --drain --force)" \
    "parse_args: flera flaggor behåller sin ordning"
assert_equals "|" \
    "$(reboot_parse_args)" \
    "parse_args: inga argument ger tomt mål"
assert_equals "controlplane-1|--drain" \
    "$(reboot_parse_args --drain controlplane-1)" \
    "parse_args: flagga före målet hittas ändå"

# --- talos_flags ------------------------------------------------------------
assert_equals "--drain" "$(reboot_talos_flags --drain)" \
    "talos_flags: --drain mappar till --drain"
assert_equals "--mode force" "$(reboot_talos_flags --force)" \
    "talos_flags: --force mappar till --mode force"
assert_equals "--mode powercycle" "$(reboot_talos_flags --powercycle)" \
    "talos_flags: --powercycle mappar till --mode powercycle"
assert_equals "--wait=false" "$(reboot_talos_flags --no-wait)" \
    "talos_flags: --no-wait mappar till --wait=false"
assert_equals "--drain --mode force" "$(reboot_talos_flags --drain --force)" \
    "talos_flags: flera flaggor slås ihop med mellanslag"
assert_equals "" "$(reboot_talos_flags)" \
    "talos_flags: inga flaggor ger tom sträng"
assert_fails "talos_flags: okänd flagga ger fel" reboot_talos_flags --starta

# --- node_ip ----------------------------------------------------------------
nodes_yaml=$(mktemp)
cat > "$nodes_yaml" <<'YAML'
nodes:
  - name: controlplane-1
    ip: "10.10.10.11"
    role: "controlplane"
    poe: 11
  - name: worker-1
    ip: "10.10.10.21"
    role: "worker"
    poe: 21
YAML

assert_equals "10.10.10.11" \
    "$(reboot_node_ip controlplane-1 "$nodes_yaml")" \
    "node_ip: controlplane-1 hittas"
assert_equals "10.10.10.21" \
    "$(reboot_node_ip worker-1 "$nodes_yaml")" \
    "node_ip: worker-1 hittas"
assert_fails "node_ip: okänd nod ger fel" reboot_node_ip worker-99 "$nodes_yaml"
assert_fails "node_ip: tomt namn ger fel" reboot_node_ip "" "$nodes_yaml"
assert_fails "node_ip: fil som inte finns ger fel" reboot_node_ip worker-1 "/tmp/saknas.yaml"

# --- node_names -------------------------------------------------------------
assert_contains "$(reboot_node_names "$nodes_yaml")" "controlplane-1" \
    "node_names: listar controlplane-1"
assert_contains "$(reboot_node_names "$nodes_yaml")" "worker-1" \
    "node_names: listar worker-1"

rm -f "$nodes_yaml"

# --- sammanfattning --------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
    echo -e "\033[32m✅ $tests tester, 0 misslyckanden\033[0m"
    exit 0
fi
echo -e "\033[31m❌ $tests tester, $failures misslyckanden\033[0m"
exit 1
