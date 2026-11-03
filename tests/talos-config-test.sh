#!/bin/bash

# Tester för de rena funktionerna i scripts/talos.sh (Talos v1.14-stödet).
# Kör: ./tests/talos-config-test.sh
#
# Funktioner som kräver en levande nod (talosctl version/upgrade) testas inte
# här - de verifieras genom att köra "simon talos update config <nod>" mot
# riktiga noder.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$here/../scripts/talos.sh"

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

YQ_BIN="$(resolve_yq)" || {
    echo "❌ yq (mikefarah) krävs för testerna"
    exit 1
}
SIMON_YQ="$YQ_BIN"

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# --- resolve_yq ------------------------------------------------------------
assert_contains "$YQ_BIN" "yq" "resolve_yq: returnerar en sökväg"
assert_contains "$("$YQ_BIN" --version 2>&1)" "mikefarah" \
    "resolve_yq: hittar mikefarah-versionen (inte jq-wrappern)"

# --- extract_machine_config_spec -------------------------------------------
# Talos v1.14 lagrar configen som en quoted string i .spec - inte som en
# literal block ("spec: |"). Den gamla implementationen letade efter
# "spec: |" och hittade ingenting.
cat > "$tmp/mc.yaml" <<'EOF'
node: 10.10.10.11
metadata:
    namespace: config
    type: MachineConfigs.config.talos.dev
    id: persistent
spec: "version: v1alpha1\nmachine:\n    type: controlplane\n---\napiVersion: v1alpha1\nkind: HostnameConfig\nhostname: controlplane-1\n"
EOF

if extract_machine_config_spec "$tmp/mc.yaml" "$tmp/spec.yaml"; then
    tests=$((tests + 1))
else
    failures=$((failures + 1))
    echo "❌ extract_machine_config_spec: quoted string-spec extraheras"
fi

assert_contains "$(cat "$tmp/spec.yaml")" "kind: HostnameConfig" \
    "extract_machine_config_spec: dokumenten finns med"
assert_contains "$(cat "$tmp/spec.yaml")" "hostname: controlplane-1" \
    "extract_machine_config_spec: innehållet finns med"

# Ett enda dokument (utan ---) ska också fungera.
cat > "$tmp/single.yaml" <<'EOF'
spec: "version: v1alpha1\nmachine:\n    type: worker\n"
EOF
extract_machine_config_spec "$tmp/single.yaml" "$tmp/single.spec" >/dev/null 2>&1
assert_equals "0" "$?" "extract_machine_config_spec: enkelt dokument går att extrahera"

assert_fails "extract_machine_config_spec: saknad fil" \
    extract_machine_config_spec "$tmp/finns-inte.yaml" "$tmp/out.yaml"

# --- talos_node_patch_file -------------------------------------------------
mkdir -p "$tmp/patches/workers/worker-1" "$tmp/patches/controlplanes"
cat > "$tmp/patches/workers/worker-1/patch.yaml" <<'EOF'
machine:
  type: worker
EOF
cat > "$tmp/patches/controlplanes/controlplane-1.yaml" <<'EOF'
machine:
  type: controlplane
EOF

assert_equals "$tmp/patches/workers/worker-1/patch.yaml" \
    "$(talos_node_patch_file worker worker-1 "$tmp/patches")" \
    "node_patch_file: worker använder workers/<nod>/patch.yaml"
assert_equals "$tmp/patches/controlplanes/controlplane-1.yaml" \
    "$(talos_node_patch_file controlplane controlplane-1 "$tmp/patches")" \
    "node_patch_file: controlplane använder controlplanes/<nod>.yaml"
assert_fails "node_patch_file: saknad patch" \
    talos_node_patch_file worker worker-99 "$tmp/patches"

# --- talos_install_match ---------------------------------------------------
# v1alpha1: machine.provisioning.diskSelector.match
cat > "$tmp/new.yaml" <<'EOF'
machine:
  type: worker
  provisioning:
    diskSelector:
      match: disk.serial == "0x00002039"
EOF
assert_equals 'disk.serial == "0x00002039"' \
    "$(talos_install_match "$tmp/new.yaml")" \
    "install_match: läser machine.provisioning.diskSelector.match"

# v1alpha1: UnattendedInstallConfig-dokument
cat > "$tmp/install.yaml" <<'EOF'
apiVersion: v1alpha1
kind: UnattendedInstallConfig
provisioning:
  diskSelector:
    match: disk.dev_path == "/dev/sda"
  wipe: false
EOF
assert_equals 'disk.dev_path == "/dev/sda"' \
    "$(talos_install_match "$tmp/install.yaml")" \
    "install_match: läser UnattendedInstallConfig"

# Legacy: machine.install.diskSelector.serial
cat > "$tmp/legacy.yaml" <<'EOF'
machine:
  type: worker
  install:
    diskSelector:
      serial: "0x00002039"
EOF
assert_equals 'disk.serial == "0x00002039"' \
    "$(talos_install_match "$tmp/legacy.yaml")" \
    "install_match: legacy serial konverteras till CEL"

# Legacy: machine.install.diskSelector.model + size
cat > "$tmp/legacy-size.yaml" <<'EOF'
machine:
  type: worker
  install:
    diskSelector:
      model: DataTraveler 3.0
      size: "<= 64GB"
EOF
assert_equals 'disk.model == "DataTraveler 3.0" && disk.size <= 68719476736u' \
    "$(talos_install_match "$tmp/legacy-size.yaml")" \
    "install_match: legacy model+size konverteras till CEL"

assert_fails "install_match: ingen selector" \
    talos_install_match "$tmp/mc.yaml"

# --- talos_install_doc -----------------------------------------------------
doc="$(talos_install_doc 'disk.serial == "0x1"' "factory.talos.dev/metal-installer/abc:v1.14.1")"
assert_contains "$doc" "kind: UnattendedInstallConfig" "install_doc: rätt kind"
assert_contains "$doc" "factory.talos.dev/metal-installer/abc:v1.14.1" "install_doc: installer-image"
assert_contains "$doc" 'disk.serial == "0x1"' "install_doc: diskSelector.match"
assert_contains "$doc" "wipe: false" "install_doc: wipe false"

# --- talos_hostname_doc ----------------------------------------------------
doc="$(talos_hostname_doc worker-1)"
assert_contains "$doc" "kind: HostnameConfig" "hostname_doc: rätt kind"
assert_contains "$doc" "worker-1" "hostname_doc: hostname"

# --- talos_normalize_user_volume ------------------------------------------
# v1.14 kräver volumeType: disk och stöder inte minSize/maxSize/grow.
cat > "$tmp/vol.yaml" <<'EOF'
apiVersion: v1alpha1
kind: UserVolumeConfig
name: ssd-1
minSize: 10GB
maxSize: 100GB
grow: true
provisioning:
  diskSelector:
    match: "'/dev/disk/by-id/usb-X' in disk.symlinks"
EOF
talos_normalize_user_volume "$tmp/vol.yaml" "$tmp/vol.out" >/dev/null 2>&1
out="$(cat "$tmp/vol.out")"
assert_contains "$out" "volumeType: disk" "normalize_volume: lägger till volumeType: disk"
assert_not_contains "$out" "minSize" "normalize_volume: tar bort minSize"
assert_not_contains "$out" "maxSize" "normalize_volume: tar bort maxSize"
assert_not_contains "$out" "grow" "normalize_volume: tar bort grow"
assert_contains "$out" "usb-X" "normalize_volume: behåller diskSelector"

# En fil som inte är en UserVolumeConfig ska avvisas.
cat > "$tmp/other.yaml" <<'EOF'
apiVersion: v1alpha1
kind: HostnameConfig
hostname: worker-1
EOF
assert_fails "normalize_volume: avvisar fel kind" \
    talos_normalize_user_volume "$tmp/other.yaml" "$tmp/other.out"

# --- yq_escape_string ------------------------------------------------------
assert_equals 'a\"b' "$(yq_escape_string 'a"b')" "yq_escape_string: citattecken"
assert_equals 'a\\b' "$(yq_escape_string 'a\b')" "yq_escape_string: backslash"

# --- talos_target_version --------------------------------------------------
mkdir -p "$tmp/repo/pxe"
cat > "$tmp/repo/pxe/generate-node-configs.py" <<'EOF'
TALOS_VERSION = "v1.14.1"
EOF
assert_equals "v1.14.1" "$(talos_target_version "$tmp/repo")" \
    "target_version: läser TALOS_VERSION ur generatorn"
assert_equals "" "$(talos_target_version "$tmp/saknas")" \
    "target_version: tomt när generatorn saknas"

# --- talos_build_node_config -----------------------------------------------
# Bygger nodens config utifrån referensnodens dokument. Kontrollerar att
# controlplane-dokumenten tas bort för workers och att hostname/token/
# installationsdisken sätts om.
cat > "$tmp/ref.yaml" <<'EOF'
version: v1alpha1
machine:
    type: controlplane
    token: 5nbict.0f2lv4dyfxfu8h6l
    ca:
        crt: Y3J0
        key: a2V5
cluster:
    token: mpgiji.f3wm33zv7jcaj7xx
    etcd:
        ca:
            crt: ZXRjZA==
---
apiVersion: v1alpha1
kind: HostnameConfig
hostname: controlplane-1
---
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
    image: ghcr.io/siderolabs/installer:v1.14.0
provisioning:
    diskSelector:
        match: disk.dev_path == "/dev/sda"
    wipe: false
---
apiVersion: v1alpha1
kind: KubeControllerManagerConfig
image: registry.k8s.io/kube-controller-manager:v1.37.0
---
apiVersion: v1alpha1
kind: KubeAuthorizerConfig
name: node
type: Node
---
apiVersion: v1alpha1
kind: KubeAuthorizerConfig
name: rbac
type: RBAC
EOF

if talos_build_node_config "$tmp/ref.yaml" worker worker-1 \
    'disk.serial == "0x1"' "factory.talos.dev/metal-installer/abc:v1.14.1" controlplane \
    "$tmp/worker.yaml" >/dev/null 2>&1; then
    tests=$((tests + 1))
else
    failures=$((failures + 1))
    echo "❌ build_node_config: bygget lyckas"
fi

worker="$(cat "$tmp/worker.yaml")"
assert_contains "$worker" "type: worker" "build_node_config: role sätts"
assert_contains "$worker" "hostname: worker-1" "build_node_config: hostname sätts"
assert_contains "$worker" 'match: disk.serial == "0x1"' "build_node_config: diskSelector sätts"
assert_contains "$worker" "factory.talos.dev/metal-installer/abc:v1.14.1" \
    "build_node_config: installer-image sätts"
assert_contains "$worker" "5nbict.0f2lv4dyfxfu8h6l" \
    "build_node_config: maskin-token kopieras från referensen"
assert_not_contains "$worker" "KubeControllerManagerConfig" \
    "build_node_config: controlplane-dokument tas bort för workers"
assert_not_contains "$worker" "KubeAuthorizerConfig" \
    "build_node_config: alla KubeAuthorizerConfig-dokument tas bort"
assert_equals "0" "$(printf '%s\n' "$worker" | grep -c 'key: a2V5')" \
    "build_node_config: CA-nyckeln töms för workers"

# Controlplane byggt från controlplane-referens: inget ska tas bort.
talos_build_node_config "$tmp/ref.yaml" controlplane controlplane-1 \
    'disk.dev_path == "/dev/sda"' "factory.talos.dev/metal-installer/abc:v1.14.1" controlplane \
    "$tmp/cp.yaml" >/dev/null 2>&1
cp="$(cat "$tmp/cp.yaml")"
assert_contains "$cp" "KubeControllerManagerConfig" \
    "build_node_config: controlplane behåller sina dokument"
assert_contains "$cp" "hostname: controlplane-1" \
    "build_node_config: controlplane-hostname sätts"

# --- sammanfattning --------------------------------------------------------
echo
if [ "$failures" -eq 0 ]; then
    echo -e "\033[32m✅ $tests tester, 0 misslyckanden\033[0m"
    exit 0
fi
echo -e "\033[31m❌ $tests tester, $failures misslyckanden\033[0m"
exit 1
