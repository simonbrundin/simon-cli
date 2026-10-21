#!/bin/bash

# =============================================================================
# Kubernetes / Talos Health Checks
# Source this file from kubernetes.sh
#
# Usage: simon cluster health [--strict] [--context <ctx>] [--fix] [--quick]
# =============================================================================

# Colors (local scope to avoid conflicts)
K8S_HEALTH_GREEN=$'\033[32m'
K8S_HEALTH_RED=$'\033[31m'
K8S_HEALTH_YELLOW=$'\033[33m'
K8S_HEALTH_BLUE=$'\033[34m'
K8S_HEALTH_RESET=$'\033[0m'

# =============================================================================
# Health Check Framework
# =============================================================================

# Global state (set by main_kubernetes_health)
K8S_HEALTH_MODE="${K8S_HEALTH_MODE:-relaxed}"
K8S_HEALTH_ERRORS=("${K8S_HEALTH_ERRORS[@]}")
K8S_HEALTH_WARNINGS=("${K8S_HEALTH_WARNINGS[@]}")
K8S_HEALTH_SUGGESTIONS=("${K8S_HEALTH_SUGGESTIONS[@]}")
K8S_HEALTH_CERT_ERROR=0
K8S_HEALTH_CONTEXT=""
K8S_HEALTH_FIX=0
K8S_HEALTH_QUICK=0
K8S_HEALTH_NODES_YAML="${K8S_HEALTH_NODES_YAML:-$HOME/repos/infrastructure/talos/nodes.yaml}"

# Tidsgränser (sekunder) - health checken ska aldrig hänga
K8S_HEALTH_CMD_TIMEOUT="${K8S_HEALTH_CMD_TIMEOUT:-30}"
K8S_HEALTH_NET_TIMEOUT="${K8S_HEALTH_NET_TIMEOUT:-10}"

# Report a hard error
# Args: message
k8s_health_error() {
    local msg="$1"
    K8S_HEALTH_ERRORS+=("$msg")
    if [ "$K8S_HEALTH_MODE" = "strict" ]; then
        echo -e "${K8S_HEALTH_RED}❌ $msg${K8S_HEALTH_RESET}"
        return 1
    fi
    # I relaxed-läge sammanfattas felen i slutet av rapporten - att skriva ut
    # dem här också ger samma rad två gånger.
    return 0
}

# Report a warning (does not fail the run)
# Args: message
k8s_health_warn() {
    local msg="$1"
    K8S_HEALTH_WARNINGS+=("$msg")
    [ "$K8S_HEALTH_MODE" = "strict" ] && \
        echo -e "${K8S_HEALTH_YELLOW}⚠ $msg${K8S_HEALTH_RESET}"
    return 0
}

# Report a suggestion for how to fix something
# Args: message
k8s_health_suggest() {
    K8S_HEALTH_SUGGESTIONS+=("$1")
    return 0
}

# Report an informational line
# Args: message
k8s_health_info() {
    echo -e "${K8S_HEALTH_BLUE}ℹ $1${K8S_HEALTH_RESET}"
    return 0
}

# Check required command exists
# Args: command_name
k8s_health_check_cmd() {
    local cmd="$1"
    if ! command -v "$cmd" >/dev/null 2>&1; then
        k8s_health_error "$cmd not found"
        return 1
    fi
    echo -e "${K8S_HEALTH_GREEN}✓ $cmd${K8S_HEALTH_RESET}"
    return 0
}

# =============================================================================
# Small helpers
# =============================================================================

# Run a command with a hard timeout so the health check can never hang
# Args: seconds command [args...]
k8s_health_timeout() {
    local secs="$1"; shift
    timeout --kill-after=5 "$secs" "$@"
}

# talosctl wrapper with timeout
k8s_health_talosctl() {
    k8s_health_timeout "$K8S_HEALTH_CMD_TIMEOUT" talosctl "$@"
}

# Snabb talosctl-wrapper (per-nod-prober) - kort timeout så att health
# checken inte tar oändligt länge på flera noder
k8s_health_talosctl_quick() {
    k8s_health_timeout "$K8S_HEALTH_NET_TIMEOUT" talosctl "$@"
}

# kubectl wrapper that always targets the selected context (with timeout)
k8s_health_kubectl() {
    local args=(--request-timeout=20s)
    if [ -n "$K8S_HEALTH_CONTEXT" ]; then
        args+=(--context "$K8S_HEALTH_CONTEXT")
    fi
    k8s_health_timeout "$K8S_HEALTH_CMD_TIMEOUT" kubectl "${args[@]}" "$@"
}

# flux wrapper with timeout
k8s_health_flux() {
    k8s_health_timeout "$K8S_HEALTH_CMD_TIMEOUT" flux "$@"
}

# Check if a TCP port is open (no netcat dependency)
# Args: host port [timeout]
k8s_health_tcp_open() {
    local host="$1" port="$2" timeout="${3:-2}"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$host" "$port" "$timeout" <<'PY' >/dev/null 2>&1 && return 0 || return 1
import socket, sys
host, port, timeout = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
sock = socket.socket()
sock.settimeout(timeout)
try:
    sock.connect((host, port))
    sys.exit(0)
except Exception:
    sys.exit(1)
finally:
    sock.close()
PY
    fi

    if command -v socat >/dev/null 2>&1; then
        socat -T"$timeout" -u /dev/null "TCP:$host:$port,connect-timeout=$timeout" >/dev/null 2>&1 && return 0 || return 1
    fi

    timeout "$timeout" bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1
}

# Days until a timestamp (RFC3339 or openssl style) - echoes an integer
# Args: date_string
k8s_health_days_until() {
    local target="$1" epoch
    epoch=$(date -d "$target" +%s 2>/dev/null) || { echo 999; return; }
    [ -z "$epoch" ] && { echo 999; return; }
    echo $(( (epoch - $(date +%s)) / 86400 ))
}

# Hours until a timestamp - echoes an integer
# Args: date_string
k8s_health_hours_until() {
    local target="$1" epoch
    epoch=$(date -d "$target" +%s 2>/dev/null) || { echo 999; return; }
    [ -z "$epoch" ] && { echo 999; return; }
    echo $(( (epoch - $(date +%s)) / 3600 ))
}

# Does a namespace exist?
# Args: namespace
k8s_health_has_ns() {
    k8s_health_kubectl get namespace "$1" >/dev/null 2>&1
}

# Does a CRD exist?
# Args: crd
k8s_health_has_crd() {
    k8s_health_kubectl get crd "$1" >/dev/null 2>&1
}

# Print a section header
# Args: title
k8s_health_section() {
    echo -e "\n${K8S_HEALTH_BLUE}$1${K8S_HEALTH_RESET}"
}

# =============================================================================
# Context resolution
# =============================================================================

# Resolve which kube context the health check should target.
# Priority: --context flag > $KUBECTL_CONTEXT > context serving the Talos
# cluster network > current context.
# Args: explicit_context
k8s_health_resolve_context() {
    local explicit="$1"
    local current contexts ctx server candidate=""

    current=$(kubectl config current-context 2>/dev/null)

    if [ -n "$explicit" ]; then
        K8S_HEALTH_CONTEXT="$explicit"
        return 0
    fi

    if [ -n "$KUBECTL_CONTEXT" ]; then
        K8S_HEALTH_CONTEXT="$KUBECTL_CONTEXT"
        return 0
    fi

    contexts=$(kubectl config get-contexts -o name 2>/dev/null)
    while IFS= read -r ctx; do
        [ -z "$ctx" ] && continue
        server=$(kubectl config view -o json 2>/dev/null | jq -r \
            --arg c "$ctx" '(.contexts[] | select(.name == $c) | .context.cluster) as $n | (.clusters[] | select(.name == $n) | .cluster.server)' 2>/dev/null)
        case "$server" in
            https://10.10.10.*|https://10.10.10:*)
                candidate="$ctx"
                break
                ;;
        esac
    done <<<"$contexts"

    if [ -n "$candidate" ]; then
        K8S_HEALTH_CONTEXT="$candidate"
    else
        K8S_HEALTH_CONTEXT="$current"
    fi

    return 0
}

k8s_health_check_context() {
    k8s_health_section "Kubernetes context..."

    if [ -z "$K8S_HEALTH_CONTEXT" ]; then
        k8s_health_error "Ingen Kubernetes-context kunde hittas"
        return 1
    fi

    local server
    server=$(kubectl config view -o json 2>/dev/null | jq -r \
        --arg c "$K8S_HEALTH_CONTEXT" '(.contexts[] | select(.name == $c) | .context.cluster) as $n | (.clusters[] | select(.name == $n) | .cluster.server)' 2>/dev/null)

    echo -e "${K8S_HEALTH_GREEN}✓ Context: $K8S_HEALTH_CONTEXT${K8S_HEALTH_RESET} ($server)"

    case "$server" in
        https://127.0.0.1:*|https://localhost:*|https://0.0.0.0:*|https://\[::1\]:*)
            k8s_health_warn "Contexten pekar på en lokal/kind-kluster ($server) - hela health checken gäller inte ditt Talos-kluster!"
            k8s_health_suggest "Använd: simon cluster health --context admin@cluster1"
            ;;
    esac

    if ! k8s_health_kubectl version >/dev/null 2>&1; then
        k8s_health_error "Kan inte ansluta till klustret med context $K8S_HEALTH_CONTEXT"
        return 1
    fi

    echo -e "${K8S_HEALTH_GREEN}✓ API-servern svarar${K8S_HEALTH_RESET}"
    return 0
}

# =============================================================================
# Tool Checks
# =============================================================================

k8s_health_check_tools() {
    k8s_health_section "Kontrollerar required tools..."
    local required=("ping" "talosctl" "kubectl" "yq" "jq" "flux")
    for cmd in "${required[@]}"; do
        k8s_health_check_cmd "$cmd"
    done

    if [ ! -f "$K8S_HEALTH_NODES_YAML" ]; then
        k8s_health_error "nodes.yaml not found: $K8S_HEALTH_NODES_YAML"
    else
        echo -e "${K8S_HEALTH_GREEN}✓ nodes.yaml${K8S_HEALTH_RESET}"
    fi
}

# =============================================================================
# Node inventory and reachability
# =============================================================================

# Read nodes from nodes.yaml into "name ip role" triplets
k8s_health_node_list() {
    [ -f "$K8S_HEALTH_NODES_YAML" ] || return 1
    yq -r '.nodes[] | [.name, .ip, .role] | @tsv' "$K8S_HEALTH_NODES_YAML" 2>/dev/null
}

# Check that every node in nodes.yaml is reachable and report per node.
# Uses ICMP *and* a TCP probe on the Talos API port, because ICMP is
# frequently blocked on the cluster VLAN.
k8s_health_check_node_inventory() {
    k8s_health_section "Nodstatus (nodes.yaml)..."

    local name ip role ping_ok tcp_ok
    local cp_total=0 cp_up=0 worker_total=0 worker_up=0
    local missing_nodes="" role_mismatch=""

    while IFS=$'\t' read -r name ip role; do
        [ -z "$name" ] && continue
        [ "$name" = "null" ] && continue

        ping_ok=0
        tcp_ok=0
        ping -c 1 -W 2 "$ip" >/dev/null 2>&1 && ping_ok=1
        k8s_health_tcp_open "$ip" 50000 2 && tcp_ok=1

        if [ "$tcp_ok" -eq 1 ]; then
            if [ "$ping_ok" -eq 1 ]; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ $name ($ip, $role) - reachable${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_YELLOW}  ⚠ $name ($ip, $role) - port 50000 öppen, ICMP blockerat${K8S_HEALTH_RESET}"
            fi
        elif [ "$ping_ok" -eq 1 ]; then
            echo -e "${K8S_HEALTH_RED}  ✗ $name ($ip, $role) - svarar på ping men Talos-API (50000) är stängt${K8S_HEALTH_RESET}"
            k8s_health_error "Talos-API är inte nåbart på $name ($ip)"
            k8s_health_restart_hint "$name" " och applicera config igen: se ~/repos/infrastructure/talos"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $name ($ip, $role) - ingen kontakt${K8S_HEALTH_RESET}"
            k8s_health_error "Noden $name ($ip) svarar inte"
            k8s_health_restart_hint "$name"
        fi

        # Track against the Kubernetes cluster membership
        if k8s_health_kubectl get node "$name" >/dev/null 2>&1; then
            # Rollen i Kubernetes ska matcha rollen i nodes.yaml
            # (Talos sätter node-role.kubernetes.io/<role>, inte kubernetes.io/role)
            local k8s_role_label
            k8s_role_label=$(k8s_health_kubectl get node "$name" -o json 2>/dev/null \
                | jq -r '.metadata.labels | keys[] | select(startswith("node-role.kubernetes.io/"))' 2>/dev/null)
            case "$role" in
                controlplane)
                    [[ "$k8s_role_label" != *"control-plane"* ]] && role_mismatch="$role_mismatch $name"
                    ;;
                worker)
                    [[ "$k8s_role_label" == *"control-plane"* ]] && role_mismatch="$role_mismatch $name"
                    ;;
            esac
        else
            missing_nodes="$missing_nodes $name"
        fi

        if [ "$role" = "controlplane" ]; then
            cp_total=$((cp_total + 1))
            [ "$tcp_ok" -eq 1 ] && cp_up=$((cp_up + 1))
        else
            worker_total=$((worker_total + 1))
            [ "$tcp_ok" -eq 1 ] && worker_up=$((worker_up + 1))
        fi
    done < <(k8s_health_node_list)

    echo ""
    echo -e "  Controlplanes reachable: $cp_up/$cp_total"
    echo -e "  Workers reachable:       $worker_up/$worker_total"

    if [ -n "$missing_nodes" ]; then
        k8s_health_warn "Följande noder finns i nodes.yaml men inte i Kubernetes:$missing_nodes"
    fi

    if [ -n "$role_mismatch" ]; then
        k8s_health_error "Rollen i nodes.yaml stämmer inte med Kubernetes node-role:$role_mismatch"
    fi
}

# Look up a single field for a node in nodes.yaml.
# Args: node_name field
k8s_health_node_field() {
    local name="$1" field="$2" value
    value=$(yq -r ".nodes[] | select(.name == \"$name\") | .[\"$field\"] // \"\"" "$K8S_HEALTH_NODES_YAML" 2>/dev/null)
    [ "$value" = "null" ] && value=""
    echo "$value"
}

# Emit restart instructions that match how the node is actually powered and
# booted. Not every node can be power-cycled from UniFi, and worker-9 (the
# MacBook) does not boot into Talos on its own - Talos has to be selected
# manually in the boot menu, otherwise the machine comes up in macOS.
# Args: node_name [extra_text_appended_to_the_poe_variant]
k8s_health_restart_hint() {
    local name="$1" extra="${2:-}"
    local manual poe

    manual=$(k8s_health_node_field "$name" 'manual-boot')
    poe=$(k8s_health_node_field "$name" 'poe')

    if [ "$manual" = "true" ]; then
        k8s_health_suggest "$name måste startas MANUELLT: starta om maskinen och välj Talos i bootmenyn (den bootar inte in i Talos automatiskt)"
        [ -n "$poe" ] && k8s_health_suggest "  -> därefter: power-cycle via PoE (UniFi port $poe)$extra"
        return 0
    fi

    if [ -n "$poe" ]; then
        k8s_health_suggest "Power-cycle $name via PoE (UniFi port $poe)$extra"
    else
        k8s_health_suggest "$name har ingen PoE-port - starta om maskinen manuellt$extra"
    fi
}

# =============================================================================
# Talos API certificates
#
# Talos issues the Talos API server certificate with a short lifetime. If the
# node cannot renew it (e.g. it is not part of the cluster) the certificate
# expires and the node becomes unreachable over the Talos API even though the
# node itself is alive and running.
# =============================================================================

k8s_health_check_talos_certs() {
    k8s_health_section "Talos API-certifikat..."

    if ! command -v openssl >/dev/null 2>&1; then
        k8s_health_info "openssl saknas - hoppar över certifikatkontroll"
        return 0
    fi

    local name ip role certinfo notafter days expired=0 broken=0
    while IFS=$'\t' read -r name ip role; do
        [ -z "$name" ] && continue
        [ "$name" = "null" ] && continue

        certinfo=$(timeout 3 openssl s_client -connect "$ip:50000" </dev/null 2>/dev/null | \
            openssl x509 -noout -enddate -subject 2>/dev/null)

        if [ -z "$certinfo" ]; then
            # No certificate presented: apid is not serving TLS (or is wedged)
            echo -e "${K8S_HEALTH_RED}  ✗ $name ($ip) - ingen TLS-handshake mot Talos-API${K8S_HEALTH_RESET}"
            k8s_health_error "Talos-API svarar inte med TLS på $name ($ip)"
            broken=$((broken + 1))
            continue
        fi

        notafter=$(echo "$certinfo" | grep -o 'notAfter=.*' | cut -d= -f2-)
        days=$(k8s_health_days_until "$notafter")
        local hours
        hours=$(k8s_health_hours_until "$notafter")

        if [ "$days" -lt 0 ]; then
            echo -e "${K8S_HEALTH_RED}  ✗ $name ($ip) - API-certifikat UTGÅNGT ($notafter)${K8S_HEALTH_RESET}"
            k8s_health_error "Talos API-certifikat på $name ($ip) har gått ut ($notafter)"
            k8s_health_restart_hint "$name" " och applicera config igen inom 24h (annars förfaller certifikatet igen)"
            K8S_HEALTH_CERT_ERROR=1
            expired=$((expired + 1))
        elif [ "$hours" -le 48 ]; then
            echo -e "${K8S_HEALTH_YELLOW}  ⚠ $name ($ip) - API-certifikat går ut om $hours timmar${K8S_HEALTH_RESET}"
            k8s_health_warn "Talos API-certifikat på $name ($ip) går ut om $hours timmar"
        else
            echo -e "${K8S_HEALTH_GREEN}  ✓ $name ($ip) - API-certifikat gäller i $days dagar${K8S_HEALTH_RESET}"
        fi
    done < <(k8s_health_node_list)

    if [ "$expired" -gt 0 ] || [ "$broken" -gt 0 ]; then
        k8s_health_suggest "Sätt machine.ca.aggregatedWorkerRole: \"\" i machine config för att undvika 24-timmarscertifikat"
    fi
}

# =============================================================================
# Talos reachability / health
# =============================================================================

# Control planes whose Talos API actually answers
k8s_health_reachable_cps() {
    local name ip role
    while IFS=$'\t' read -r name ip role; do
        [ "$role" = "controlplane" ] || continue
        [ -z "$name" ] && continue
        if k8s_health_talosctl_quick version --nodes "$ip" >/dev/null 2>&1; then
            echo "$ip"
        fi
    done < <(k8s_health_node_list)
}

# Every node whose Talos API answers, regardless of role (comma separated)
k8s_health_reachable_nodes_csv() {
    local name ip role out=""
    while IFS=$'\t' read -r name ip role; do
        [ -z "$name" ] || [ "$name" = "null" ] && continue
        if k8s_health_talosctl_quick version --nodes "$ip" >/dev/null 2>&1; then
            out="${out:+$out,}$ip"
        fi
    done < <(k8s_health_node_list)
    echo "$out"
}

k8s_health_check_talos_api() {
    k8s_health_section "Talos API..."

    local name ip role
    local reachable=0 broken=0

    while IFS=$'\t' read -r name ip role; do
        [ -z "$name" ] && continue
        [ "$name" = "null" ] && continue

        if k8s_health_talosctl_quick version --nodes "$ip" >/dev/null 2>&1; then
            local talos_version
            talos_version=$(k8s_health_talosctl_quick version --nodes "$ip" 2>/dev/null | awk '/Server:/{f=1} f&&/Tag:/{print $2; exit}')
            echo -e "${K8S_HEALTH_GREEN}  ✓ $name ($ip) - Talos API OK ${talos_version:-}${K8S_HEALTH_RESET}"
            reachable=$((reachable + 1))
        else
            local err
            err=$(k8s_health_talosctl_quick version --nodes "$ip" 2>&1 | grep -oE "(certificate has expired[^']*|connection error[^']*|no route to host|connection refused)" | head -1)
            echo -e "${K8S_HEALTH_RED}  ✗ $name ($ip) - Talos API svarar inte${err:+ ($err)}${K8S_HEALTH_RESET}"
            broken=$((broken + 1))
        fi
    done < <(k8s_health_node_list)

    if [ "$reachable" -eq 0 ]; then
        k8s_health_error "Ingen node svarar på Talos API"
        return 1
    fi
    return 0
}

k8s_health_check_talos_health() {
    k8s_health_section "talosctl health..."

    local cps
    cps=$(k8s_health_reachable_cps)

    if [ -z "$cps" ]; then
        k8s_health_error "talosctl health - ingen controlplane är nåbar"
        return 1
    fi

    local talos_output
    # talosctl health kräver exakt en nod. wait-timeout sätts lågt så att
    # health checken inte hänger i 20 minuter.
    talos_output=$(k8s_health_timeout 120 talosctl health --nodes "$(echo "$cps" | head -1)" --wait-timeout 45s 2>&1)
    if [ $? -ne 0 ]; then
        k8s_health_error "talosctl health failed"
        echo "$talos_output"
        return 1
    fi

    echo "$talos_output" | while IFS= read -r line; do
        if [[ "$line" == *": OK" ]] || [[ "$line" == *"..." ]]; then
            echo -e "${K8S_HEALTH_GREEN}${line}${K8S_HEALTH_RESET}"
        else
            echo "$line"
        fi
    done
    return 0
}

# =============================================================================
# etcd
# =============================================================================

k8s_health_check_etcd() {
    k8s_health_section "etcd..."

    local cps
    cps=$(k8s_health_reachable_cps)
    if [ -z "$cps" ]; then
        k8s_health_error "Kan inte kontrollera etcd - ingen controlplane är nåbar"
        return 1
    fi

    local members_out status_out
    # Fråga ALLA nåbara controlplanes - talosctl etcd status med en nod
    # returnerar bara den nodens rad.
    local cp_csv
    cp_csv=$(echo "$cps" | paste -sd, -)
    members_out=$(k8s_health_talosctl etcd members --nodes "$cp_csv" 2>&1)
    status_out=$(k8s_health_talosctl etcd status --nodes "$cp_csv" 2>&1)

    # Unika medlemmar (talosctl kan skriva ut tabellen flera gånger)
    local member_count
    member_count=$(echo "$members_out" | awk 'NR>1 && NF>2 {print $2}' | sort -u | grep -c .)

    local expected_cps
    expected_cps=$(yq -r '[.nodes[] | select(.role == "controlplane")] | length' "$K8S_HEALTH_NODES_YAML" 2>/dev/null)

    # Kolumnindex fungerar inte via headern: "DB SIZE" och "IN USE" är två
    # fält i headern men data-radens värden har olika antal fält.
    # Leader är däremot alltid ett 16-teckens hex-id som kommer EFTER
    # medlems-id:t (fält 2) - det hittar vi med en mönstermatchning.
    local leader_id
    leader_id=$(echo "$status_out" | awk '
        NR > 1 && NF > 8 {
            for (i = 3; i <= NF; i++) {
                if ($i ~ /^[0-9a-f]{16}$/ && $i != $2) { print $i; exit }
            }
        }
    ' | head -1)

    # Varje rad anger VILKEN medlem som är leader. Kolumnen hittas genom att
    # söka efter leader-värdet i raden (det finns i alla rader, även i
    # leader-radens egen rad där det är samma värde som $2).
    # Raden markeras [LEADER] när nodens eget medlems-id ($2) är leader-id:t.
    echo "$status_out" | awk -v leader="$leader_id" '
        NR > 1 && NF > 8 && leader != "" {
            raft = "?"
            for (i = 3; i <= NF; i++) {
                if ($i == leader) { raft = (i < NF ? $(i + 1) : "?"); break }
            }
            marker = ($2 == leader ? " [LEADER]" : "")
            if ($12 == "true") marker = marker " [LEARNER]"
            printf "  %-15s %-18s db=%s%s in-use=%s%s%s raft=%-8s%s\n", $1, $2, $3, $4, $5, $6, $7, raft, marker
        }
    '

    if [ "$member_count" -eq 0 ]; then
        k8s_health_error "etcd members kunde inte hämtas"
        echo "$members_out"
        return 1
    fi

    if echo "$status_out" | grep -qiE "no leader|unhealthy|failed to"; then
        k8s_health_error "etcd rapporterar fel (se output ovan)"
        k8s_health_suggest "talosctl etcd status --nodes <cp> - kontrollera quorum"
    elif [ -z "$leader_id" ] || [ "$leader_id" = "0000000000000000" ]; then
        k8s_health_error "etcd har ingen leader"
        k8s_health_suggest "talosctl etcd status --nodes <cp> - kontrollera quorum"
    else
        local leader_name
        leader_name=$(echo "$members_out" | awk -v id="$leader_id" '$2 == id {print $3; exit}')
        echo -e "${K8S_HEALTH_GREEN}  ✓ etcd leader: ${leader_name:-$leader_id}${K8S_HEALTH_RESET}"
    fi

    if [ -n "$expected_cps" ] && [ "$expected_cps" != "null" ] && [ "$member_count" -lt "$expected_cps" ]; then
        k8s_health_error "etcd har $member_count/$expected_cps controlplane-medlemmar - quorum är bräckligt"
        k8s_health_suggest "Återställ controlplane-1 (talosctl reset --system-labels-to-wipe=EPHEMERAL) och bootstrap om den"
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ etcd quorum: $member_count/$expected_cps medlemmar${K8S_HEALTH_RESET}"
    fi
}

# =============================================================================
# Kubernetes nodes
# =============================================================================

k8s_health_check_k8s_nodes() {
    k8s_health_section "Kubernetes-noder..."

    local notready=0
    local node ready
    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        ready=$(k8s_health_kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        local line
        line=$(k8s_health_kubectl get node "$node" 2>/dev/null | tail -1)
        if [ "$ready" = "True" ]; then
            echo -e "${K8S_HEALTH_GREEN}✓ $line${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}✗ $line${K8S_HEALTH_RESET}"
            notready=$((notready + 1))
        fi
    done

    [ "$notready" -gt 0 ] && k8s_health_error "$notready nod(er) är inte Ready"
    return 0
}

k8s_health_check_node_conditions() {
    k8s_health_section "Node conditions & resurser..."

    local node
    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local ready pressure taints
        ready=$(k8s_health_kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
        pressure=$(k8s_health_kubectl get node "$node" -o json 2>/dev/null | jq -r \
            '[.status.conditions[] | select(.type | test("Pressure")) | select(.status == "True") | .type] | join(",")' 2>/dev/null)
        taints=$(k8s_health_kubectl get node "$node" -o json 2>/dev/null | jq -r \
            '[.spec.taints[]? | .key] | join(",")' 2>/dev/null)

        if [ "$ready" = "True" ] && [ -z "$pressure" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $node: Ready${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $node: Ready=$ready ${pressure:+pressure=$pressure}${K8S_HEALTH_RESET}"
            k8s_health_error "Noden $node har problem (Ready=$ready ${pressure:+$pressure})"
        fi

        if [ -n "$taints" ]; then
            echo -e "${K8S_HEALTH_YELLOW}    • taints: $taints${K8S_HEALTH_RESET}"
        fi
    done

    # Version skew between nodes
    local versions
    versions=$(k8s_health_kubectl get nodes -o jsonpath='{range .items[*]}{.status.nodeInfo.kubeletVersion}{"\n"}{end}' 2>/dev/null | sort -u)
    local vcount
    vcount=$(echo "$versions" | grep -c . )
    if [ "$vcount" -gt 1 ]; then
        k8s_health_warn "Version-skew mellan noder: $(echo "$versions" | paste -sd' ' -)"
    fi
}

k8s_health_check_node_resources() {
    k8s_health_section "Nodresurser..."

    # Nyckelord: "reserverad" = capacity minus det kubelet håller reservat till
    # systemet. Det är INTE användning - den mäts via metrics-api:et eller,
    # för minne, via talosctl memory.
    local node ip reserved mem_used_pct mem_total_mb node_json
    local any=0 metrics_available=0

    # Spara minnesanvändning från Talos (fungerar utan metrics-server)
    local talos_mem=""
    if [ "$K8S_HEALTH_QUICK" -eq 0 ]; then
        local reachable_csv
        reachable_csv=$(k8s_health_reachable_nodes_csv)
        [ -n "$reachable_csv" ] && talos_mem=$(k8s_health_talosctl memory --nodes "$reachable_csv" 2>/dev/null)
    fi

    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        ip=$(k8s_health_kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)

        node_json=$(k8s_health_kubectl get node "$node" -o json 2>/dev/null)
        reserved=$(echo "$node_json" | jq -r '
            def millis: if type == "number" then . else (if endswith("m") then (.[:-1] | tonumber) else (tonumber * 1000) end) end;
            def bytes: if type == "number" then . else
                (if endswith("Ki") then (.[:-2] | tonumber) * 1024
                 elif endswith("Mi") then (.[:-2] | tonumber) * 1048576
                 elif endswith("Gi") then (.[:-2] | tonumber) * 1073741824
                 else tonumber end) end;
            def pct: if (.status.capacity.cpu | millis) == 0 then "?"
                    else ((.status.allocatable.cpu | millis) * 100 / (.status.capacity.cpu | millis) | floor | tostring) + "%" end;
            "CPU " + pct + " / minne " + (
                if (.status.capacity.memory | bytes) == 0 then "?"
                else ((.status.allocatable.memory | bytes) * 100 / (.status.capacity.memory | bytes) | floor | tostring) + "%" end)' 2>/dev/null)

        local line="$reserved reserverad för systemet"

        # Riktig användning via metrics-api
        local top
        top=$(k8s_health_kubectl top node "$node" 2>/dev/null | awk 'NR==2 {print "CPU " $2 ", minne " $3}')
        if [ -n "$top" ]; then
            metrics_available=1
            line="$line | användning: $top"
        fi

        # Minnesanvändning direkt från Talos (oberoende av metrics-server)
        mem_used_pct=""
        if [ -n "$talos_mem" ] && [ -n "$ip" ]; then
            mem_used_pct=$(echo "$talos_mem" | awk -v ip="$ip" '$1 == ip {
                total = $2; used = $3
                if (total > 0) printf "%d", (used * 100 / total)
            }')
            mem_total_mb=$(echo "$talos_mem" | awk -v ip="$ip" '$1 == ip {print $2; exit}')
            [ -n "$mem_used_pct" ] && line="$line | minne använt: ${mem_used_pct}% av ${mem_total_mb} MB"
        fi

        local color="$K8S_HEALTH_GREEN"
        if [ -n "$mem_used_pct" ] && [ "$mem_used_pct" -ge 90 ] 2>/dev/null; then
            color="$K8S_HEALTH_RED"
            k8s_health_warn "Minnesanvändning på $node är ${mem_used_pct}% (>= 90%)"
        elif [ -n "$mem_used_pct" ] && [ "$mem_used_pct" -ge 80 ] 2>/dev/null; then
            color="$K8S_HEALTH_YELLOW"
        fi

        echo -e "${color}  $node: $line${K8S_HEALTH_RESET}"
        any=1
    done

    [ "$any" -eq 0 ] && echo -e "${K8S_HEALTH_YELLOW}  ⚠ Inga noder att kontrollera${K8S_HEALTH_RESET}"

    if [ "$metrics_available" -eq 0 ] && [ "$any" -gt 0 ]; then
        echo -e "${K8S_HEALTH_BLUE}  ℹ metrics-api:et är inte installerat - CPU-användning kan inte mätas${K8S_HEALTH_RESET}"
        echo -e "${K8S_HEALTH_BLUE}    (minnesanvändning läses istället direkt från Talos)${K8S_HEALTH_RESET}"
    fi
}

# =============================================================================
# Workloads
# =============================================================================

k8s_health_check_pods() {
    k8s_health_section "Poddar (alla namespaces)..."

    local total bad
    total=$(k8s_health_kubectl get pods -A --no-headers 2>/dev/null | wc -l)
    if [ "$total" -eq 0 ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga poddar${K8S_HEALTH_RESET}"
        return 0
    fi

    # Pods that are not Running/Completed
    local not_running
    not_running=$(k8s_health_kubectl get pods -A --no-headers 2>/dev/null | awk '$4 != "Running" && $4 != "Completed"')

    if [ -z "$not_running" ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ Alla $total poddar kör${K8S_HEALTH_RESET}"
    else
        local count
        count=$(echo "$not_running" | grep -c .)
        echo -e "${K8S_HEALTH_RED}  ✗ $count/$total poddar kör inte normalt${K8S_HEALTH_RESET}"
        echo "$not_running" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo -e "${K8S_HEALTH_RED}    $line${K8S_HEALTH_RESET}"
        done
        k8s_health_error "$count poddar är inte Running/Completed"
    fi

    # Specific failure modes worth calling out
    local crashloop imagepull
    crashloop=$(k8s_health_kubectl get pods -A --no-headers 2>/dev/null | grep -c "CrashLoopBackOff")
    imagepull=$(k8s_health_kubectl get pods -A --no-headers 2>/dev/null | grep -c "ImagePullBackOff\|ErrImagePull")
    [ "$crashloop" -gt 0 ] && k8s_health_error "$crashloop poddar i CrashLoopBackOff"
    [ "$imagepull" -gt 0 ] && k8s_health_error "$imagepull poddar kan inte hämta image"

    # Restart heavy pods
    local restarts
    restarts=$(k8s_health_kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[]
        | select([.status.containerStatuses[]?.restartCount] | add > 5)
        | "\(.metadata.namespace)/\(.metadata.name): \([.status.containerStatuses[]?.restartCount] | add) omstarter"
    ' 2>/dev/null)
    if [ -n "$restarts" ]; then
        echo -e "${K8S_HEALTH_YELLOW}  • Poddar med omstarter:${K8S_HEALTH_RESET}"
        echo "$restarts" | while IFS= read -r line; do
            [ -z "$line" ] && continue
            echo -e "${K8S_HEALTH_YELLOW}    $line${K8S_HEALTH_RESET}"
        done
    fi

    # Pods stuck in Terminating
    local terminating
    terminating=$(k8s_health_kubectl get pods -A --no-headers 2>/dev/null | grep -c "Terminating")
    if [ "$terminating" -gt 0 ]; then
        k8s_health_warn "$terminating poddar står i Terminating"
        k8s_health_suggest "simon kubernetes remove finalizers (välj namespace) - eller kör health --fix"
    fi
}

k8s_health_check_kube_system() {
    k8s_health_section "kube-system..."

    local bad=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"Running"* ]] || [[ "$line" == *"Completed"* ]]; then
            echo -e "${K8S_HEALTH_GREEN}✓ $line${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}✗ $line${K8S_HEALTH_RESET}"
            bad=$((bad + 1))
        fi
    done < <(k8s_health_kubectl get pods -n kube-system --no-headers 2>/dev/null)

    [ "$bad" -gt 0 ] && k8s_health_error "$bad poddar i kube-system är inte Running"
}

# Senaste varning-events - fångar problem som inte syns i nod/pod-status
k8s_health_check_events() {
    k8s_health_section "Senaste events..."

    local events_json
    events_json=$(k8s_health_kubectl get events -A --field-selector type=Warning -o json 2>/dev/null)
    if [ -z "$events_json" ]; then
        echo -e "${K8S_HEALTH_BLUE}  ℹ Kunde inte hämta events${K8S_HEALTH_RESET}"
        return 0
    fi

    local count
    count=$(echo "$events_json" | jq -r '[.items[]?] | length' 2>/dev/null)
    [ -z "$count" ] || [ "$count" = "null" ] && count=0

    if [ "$count" -eq 0 ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga warning-events${K8S_HEALTH_RESET}"
        return 0
    fi

    echo -e "  $count warning-events, visar de 10 senaste:"
    echo "$events_json" | jq -r '
        [.items[]?]
        | sort_by(.lastTimestamp // .eventTime // "")
        | reverse
        | .[0:10][]
        | "  ⚠ \(.metadata.namespace)/\(.involvedObject.kind)/\(.involvedObject.name): \(.reason) - \(.message)"
    ' 2>/dev/null | while IFS= read -r line; do
        [ -n "$line" ] && echo -e "${K8S_HEALTH_YELLOW}${line}${K8S_HEALTH_RESET}"
    done

    # Samma reason på samma objekt flera gånger = strukturellt problem
    local repeated
    repeated=$(echo "$events_json" | jq -r '
        [.items[]?]
        | group_by(.involvedObject.kind + "/" + (.involvedObject.name // "") + "/" + .reason)
        | map(select(length > 2))
        | sort_by(-length)[]
        | "\(length)x \(.[0].involvedObject.kind)/\(. [0].involvedObject.name): \(.[0].reason)"
    ' 2>/dev/null | head -3)
    if [ -n "$repeated" ]; then
        echo ""
        echo -e "${K8S_HEALTH_YELLOW}  Återkommande event:${K8S_HEALTH_RESET}"
        echo "$repeated" | while IFS= read -r line; do
            [ -n "$line" ] && echo -e "${K8S_HEALTH_YELLOW}  ⚠ $line${K8S_HEALTH_RESET}"
        done
    fi

    k8s_health_suggest "kubectl get events -A --field-selector type=Warning --sort-by=.lastTimestamp"
}

k8s_health_check_storage() {
    k8s_health_section "Storage..."

    local pending
    pending=$(k8s_health_kubectl get pvc -A --no-headers 2>/dev/null | grep -c "Pending")
    if [ "$pending" -gt 0 ]; then
        k8s_health_error "$pending PVC(s) är Pending"
        k8s_health_kubectl get pvc -A 2>/dev/null | grep "Pending" | while IFS= read -r l; do
            echo -e "${K8S_HEALTH_RED}    $l${K8S_HEALTH_RESET}"
        done
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga pending PVC${K8S_HEALTH_RESET}"
    fi

    local sc default_sc
    sc=$(k8s_health_kubectl get storageclass 2>/dev/null | awk 'NR>1 && NF {print $1}' | paste -sd', ' -)
    default_sc=$(k8s_health_kubectl get storageclass -o jsonpath='{.items[?(@.metadata.annotations.storageclass\.kubernetes\.io/is-default-class=="true")].metadata.name}' 2>/dev/null)
    if [ -n "$sc" ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ StorageClasses: $sc (default: ${default_sc:-ingen})${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_YELLOW}  ⚠ Inga StorageClasses installerade${K8S_HEALTH_RESET}"
    fi
    [ -z "$default_sc" ] && [ -n "$sc" ] && k8s_health_warn "Ingen default StorageClass satt"
}

k8s_health_check_dns() {
    k8s_health_section "DNS..."

    if ! k8s_health_has_ns kube-system; then
        k8s_health_info "kube-system saknas - hoppar över DNS"
        return 0
    fi

    local coredns
    coredns=$(k8s_health_kubectl get deployment -n kube-system -l k8s-app=kube-dns -o jsonpath='{.items[0].status.readyReplicas}/{.items[0].spec.replicas}' 2>/dev/null)
    if [ -z "$coredns" ] || [ "$coredns" = "/" ]; then
        echo -e "${K8S_HEALTH_YELLOW}  ⚠ CoreDNS hittades inte${K8S_HEALTH_RESET}"
    else
        local ready_replicas want_replicas
        ready_replicas="${coredns%%/*}"
        want_replicas="${coredns##*/}"
        if [ "$ready_replicas" = "$want_replicas" ] && [ "$want_replicas" != "0" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ CoreDNS $coredns${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ CoreDNS $coredns${K8S_HEALTH_RESET}"
            k8s_health_error "CoreDNS är inte fullt redo ($coredns)"
        fi
    fi
}

k8s_health_check_network() {
    k8s_health_section "Nätverk & routing..."

    local reported=0
    local cps
    cps=$(k8s_health_reachable_cps)

    # 1. CNI/kube-proxy-poddar per nod - utan dem finns ingen pod-nätverksrkning
    local node cni_bad=0
    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local not_ready
        not_ready=$(k8s_health_kubectl get pods -A --field-selector "spec.nodeName=$node" --no-headers 2>/dev/null \
            | grep -E "kube-flannel|kube-proxy|cilium|calico" | grep -vc " Running " || true)
        [ "${not_ready:-0}" -gt 0 ] && cni_bad=$((cni_bad + 1))
    done
    if [ "$cni_bad" -eq 0 ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ CNI (flannel/kube-proxy) kör på alla noder${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_RED}  ✗ CNI/kube-proxy har problem på $cni_bad nod(er)${K8S_HEALTH_RESET}"
        k8s_health_error "CNI/kube-proxy har problem på $cni_bad nod(er)"
    fi
    reported=1

    # 2. Varje nod ska ha en InternalIP
    local no_ip=""
    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local ip
        ip=$(k8s_health_kubectl get node "$node" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}' 2>/dev/null)
        [ -z "$ip" ] && no_ip="$no_ip $node"
    done
    if [ -z "$no_ip" ]; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ Alla noder har en InternalIP${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_RED}  ✗ Noder utan InternalIP:$no_ip${K8S_HEALTH_RESET}"
        k8s_health_error "Noder saknar InternalIP:$no_ip"
    fi

    # 3. Endpoint-punkt
    #    -Det som kubectl faktiskt använder (kubeconfig) MÅSTE svara
    #    -Den konfigurerade controlPlane-endpointen (vanligtvis en VIP) bör
    #     också svara, annars går failover sönder
    local endpoint_label
    endpoint_label=$(k8s_health_kubectl config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null)

    if [ -n "$endpoint_label" ]; then
        local host port
        host=$(echo "$endpoint_label" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')
        port=$(echo "$endpoint_label" | sed -nE 's#.*:([0-9]+).*#\1#p')
        [ -z "$port" ] && port=6443
        if k8s_health_tcp_open "$host" "$port" 2; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ kubeconfig-endpoint $endpoint_label svarar${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ kubeconfig-endpoint $endpoint_label svarar inte${K8S_HEALTH_RESET}"
            k8s_health_error "kubeconfig-endpoint $endpoint_label svarar inte"
        fi
    fi

    # Konfigurerad control plane-endpoint (VIP) - kontrolleras via Talos config
    local cp_ip configured_endpoint
    cp_ip=$(echo "$cps" | head -1)
    if [ -n "$cp_ip" ]; then
        # Endpointen ligger i KubeClusterConfig-dokumentet (maskconfigen är
        # multi-doc), inte i machine.config.cluster.controlPlane. Enkel grep
        # på första endpointen skulle träffa discovery.talos.dev och KMS.
        configured_endpoint=$(k8s_health_talosctl_quick get machineconfig --nodes "$cp_ip" -o json 2>/dev/null \
            | jq -r '.spec' 2>/dev/null \
            | awk '/^kind: KubeClusterConfig/{inblock=1} inblock && /^endpoint:/{print $2; exit}')
    fi
    if [ -n "$configured_endpoint" ] && [ "$configured_endpoint" != "null" ]; then
        local chost cport
        chost=$(echo "$configured_endpoint" | sed -E 's#^https?://##; s#/.*$##; s#:.*$##')
        cport=$(echo "$configured_endpoint" | sed -nE 's#.*:([0-9]+).*#\1#p')
        [ -z "$cport" ] && cport=6443
        if k8s_health_tcp_open "$chost" "$cport" 2; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ controlPlane-endpoint $configured_endpoint svarar${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ controlPlane-endpoint $configured_endpoint svarar inte${K8S_HEALTH_RESET}"
            k8s_health_error "controlPlane-endpoint $configured_endpoint svarar inte (VIP saknas på noderna?)"
            k8s_health_suggest "talosctl get addressstatus --nodes $cp_ip - kontrollera VIP:en"
        fi
    fi

    # 4. Gateway API (om den är installerad)
    local gw_count
    gw_count=$(k8s_health_kubectl get gateways.gateway.networking.k8s.io -A --no-headers 2>/dev/null | wc -l)
    if [ "$gw_count" -gt 0 ]; then
        local programmed
        programmed=$(k8s_health_kubectl get gateways.gateway.networking.k8s.io -A -o json 2>/dev/null | jq -r \
            '[.items[] | select((.status.conditions[]? | select(.type=="Programmed") | .status) != "True")] | length' 2>/dev/null)
        if [ "$programmed" = "0" ] || [ -z "$programmed" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ Alla $gw_count Gateway är Programmerade${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $programmed Gateway är inte Programmerade${K8S_HEALTH_RESET}"
            k8s_health_error "$programmed Gateway(s) är inte Programmerade"
        fi

        local routes
        routes=$(k8s_health_kubectl get httproute -A --no-headers 2>/dev/null | wc -l)
        if [ "$routes" -gt 0 ]; then
            local accepted
            accepted=$(k8s_health_kubectl get httproute -A -o json 2>/dev/null | jq -r \
                '[.items[] | select((.status.parents[]? | select(.conditions[]? | select(.type=="Accepted") | .status) != "True")] | length' 2>/dev/null)
            if [ "$accepted" = "0" ] || [ -z "$accepted" ]; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ Alla $routes HTTPRoute är Accepted${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_RED}  ✗ $accepted HTTPRoute(s) är inte Accepted${K8S_HEALTH_RESET}"
                k8s_health_error "$accepted HTTPRoute(s) är inte Accepted"
            fi
        fi
    else
        echo -e "${K8S_HEALTH_BLUE}  ℹ Gateway API är inte installerat (inga Gateway/HTTPRoute att kontrollera)${K8S_HEALTH_RESET}"
    fi

    [ "$reported" -eq 0 ] && echo -e "${K8S_HEALTH_YELLOW}  ⚠ Inga nätverkskontroller kunde köras${K8S_HEALTH_RESET}"
}

# =============================================================================
# Flux GitOps
# =============================================================================

k8s_health_check_flux_pods() {
    k8s_health_section "Flux controllers..."

    if ! k8s_health_has_ns flux-system; then
        k8s_health_info "flux-system namespace finns inte (Flux är inte installerat)"
        return 0
    fi

    local has_error=0
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        if [[ "$line" == *"Running"* ]] || [[ "$line" == *"Completed"* ]]; then
            echo -e "${K8S_HEALTH_GREEN}$line${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}✗ $line${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done < <(k8s_health_kubectl get pods -n flux-system --no-headers 2>/dev/null)

    [ $has_error -eq 1 ] && k8s_health_error "Det finns poddar som inte kör i flux-system"
}

k8s_health_check_flux_kustomizations() {
    k8s_health_section "Kustomizations..."

    if ! k8s_health_has_ns flux-system; then
        k8s_health_info "Flux är inte installerat"
        return 0
    fi
    if ! command -v flux >/dev/null 2>&1; then
        k8s_health_warn "flux CLI saknas - hoppar över"
        return 0
    fi

    local errors=0
    local line
    while IFS= read -r line; do
        [[ "$line" =~ ^NAME ]] && continue
        [[ -z "$line" ]] && continue

        local name ready message
        ready=$(echo "$line" | awk -F'\t' '{print $5}' | xargs)
        name=$(echo "$line" | awk -F'\t' '{print $2}')
        message=$(echo "$line" | awk -F'\t' '{for (i=6; i<=NF; i++) printf "%s ", $i; print ""}')

        if [ "$ready" = "True" ] || [ "$ready" = "Ready" ]; then
            echo -e "  ${K8S_HEALTH_GREEN}✓ $name${K8S_HEALTH_RESET}"
        else
            echo -e "  ${K8S_HEALTH_RED}✗ $name: $message${K8S_HEALTH_RESET}"
            errors=$((errors + 1))
        fi
    done < <(k8s_health_flux get kustomizations -A 2>/dev/null | awk 'NR>1 && $1!="" {print}')

    [ "$errors" -gt 0 ] && k8s_health_error "Det finns $errors Kustomizations som inte är Reconciled"
}

k8s_health_check_flux_sources() {
    k8s_health_section "Flux Sources..."

    if ! k8s_health_has_ns flux-system; then
        k8s_health_info "Flux är inte installerat"
        return 0
    fi
    if ! command -v flux >/dev/null 2>&1; then
        return 0
    fi

    local errors=0
    while IFS= read -r line; do
        [[ "$line" =~ ^NAME ]] && continue
        [[ -z "$line" ]] && continue

        local name ready message
        ready=$(echo "$line" | awk -F'\t' '{print $5}' | xargs)
        name=$(echo "$line" | awk -F'\t' '{print $2}')
        message=$(echo "$line" | awk -F'\t' '{for (i=6; i<=NF; i++) printf "%s ", $i; print ""}')

        if [ "$ready" = "True" ]; then
            echo -e "  ${K8S_HEALTH_GREEN}✓ $name${K8S_HEALTH_RESET}"
        else
            echo -e "  ${K8S_HEALTH_RED}✗ $name${K8S_HEALTH_RESET} → $message"
            errors=$((errors + 1))
        fi
    done < <(k8s_health_flux get sources oci -A 2>/dev/null; k8s_health_flux get sources helm -A 2>/dev/null; k8s_health_flux get sources git -A 2>/dev/null)

    [ "$errors" -gt 0 ] && k8s_health_error "Det finns $errors Flux Sources som inte är Ready"
}

k8s_health_check_helmreleases() {
    k8s_health_section "HelmReleases..."

    if ! k8s_health_has_ns flux-system; then
        k8s_health_info "Flux är inte installerat"
        return 0
    fi
    if ! command -v flux >/dev/null 2>&1; then
        return 0
    fi

    local errors=0
    while IFS= read -r line; do
        [[ "$line" =~ ^NAME ]] && continue
        [[ -z "$line" ]] && continue

        local name ready message
        ready=$(echo "$line" | awk -F'\t' '{print $5}' | xargs)
        name=$(echo "$line" | awk -F'\t' '{print $2}')
        message=$(echo "$line" | awk -F'\t' '{for (i=6; i<=NF; i++) printf "%s ", $i; print ""}')

        if [ "$ready" = "True" ]; then
            echo -e "  ${K8S_HEALTH_GREEN}✓ $name${K8S_HEALTH_RESET}"
        else
            echo -e "  ${K8S_HEALTH_RED}✗ $name${K8S_HEALTH_RESET} → $message"
            errors=$((errors + 1))
        fi
    done < <(k8s_health_flux get helmreleases -A 2>/dev/null)

    [ "$errors" -gt 0 ] && k8s_health_error "Det finns $errors HelmReleases som inte är Ready"
}

# =============================================================================
# CSR & Certificates
# =============================================================================

k8s_health_check_csrs() {
    k8s_health_section "Pending CSR..."

    local pending
    pending=$(k8s_health_kubectl get csr --no-headers 2>/dev/null | grep -c "Pending")

    if [ "$pending" -gt 0 ]; then
        k8s_health_error "Det finns $pending pending CSR som behöver godkännas"
        k8s_health_kubectl get csr 2>/dev/null | grep "Pending"
        k8s_health_suggest "simon kubernetes approve csr"
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga pending CSR${K8S_HEALTH_RESET}"
    fi
}

k8s_health_check_csr_approver() {
    k8s_health_section "Kubelet CSR Approver..."

    if ! k8s_health_has_ns kubelet-csr-approver; then
        k8s_health_info "kubelet-csr-approver är inte installerat (ska vara extraManifest i cluster-config)"
        return 0
    fi

    local has_error=0
    local desired ready
    desired=$(k8s_health_kubectl get deployment kubelet-csr-approver -n kubelet-csr-approver -o jsonpath='{.spec.replicas}' 2>/dev/null)
    [ -z "$desired" ] && desired=1
    ready=$(k8s_health_kubectl get deployment kubelet-csr-approver -n kubelet-csr-approver -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
    [ -z "$ready" ] && ready=0

    if [ "$ready" -ge "$desired" ] 2>/dev/null; then
        echo -e "${K8S_HEALTH_GREEN}  ✓ Deployment ready ($ready/$desired replicas)${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_RED}  ✗ Deployment not ready ($ready/$desired replicas)${K8S_HEALTH_RESET}"
        has_error=1
    fi

    while IFS= read -r pod_line; do
        [ -z "$pod_line" ] && continue
        local ready_status ready_num running
        ready_status=$(echo "$pod_line" | awk '{print $2}')
        ready_num=$(echo "$ready_status" | cut -d'/' -f1)
        running=$(echo "$ready_status" | cut -d'/' -f2)

        if [[ "$pod_line" == *"Running"* ]] && [ "$ready_num" -eq "$running" ] 2>/dev/null; then
            echo -e "${K8S_HEALTH_GREEN}✓ $pod_line${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}✗ $pod_line${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done < <(k8s_health_kubectl get pods -n kubelet-csr-approver --no-headers 2>/dev/null)

    [ $has_error -eq 1 ] && k8s_health_error "Kubelet CSR Approver har problem"
}

k8s_health_check_certificates() {
    k8s_health_section "Certificate Expiration Checks..."

    if ! command -v openssl >/dev/null 2>&1; then
        k8s_health_info "openssl saknas - hoppar över certifikatkontroller"
        return 0
    fi

    # Days until expiry from a PEM
    k8s_cert_days_until_expiry() {
        local pem="$1" notafter
        notafter=$(echo "$pem" | openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)
        [ -z "$notafter" ] && { echo 999; return; }
        k8s_health_days_until "$notafter"
    }

    k8s_check_cert() {
        local name="$1" days="$2" warn=30 crit=7

        if [ "$days" -le "$crit" ]; then
            echo -e "${K8S_HEALTH_RED}  ✗ $name (expires in $days days)${K8S_HEALTH_RESET}"
            return 1
        fi
        if [ "$days" -le "$warn" ]; then
            echo -e "${K8S_HEALTH_YELLOW}  ⚠ $name (expires in $days days)${K8S_HEALTH_RESET}"
            return 0
        fi
        echo -e "${K8S_HEALTH_GREEN}  ✓ $name ($days days remaining)${K8S_HEALTH_RESET}"
        return 0
    }

    # API Server
    echo -e "${K8S_HEALTH_YELLOW}  API Server Certificate...${K8S_HEALTH_RESET}"
    local api_cert
    api_cert=$(k8s_health_kubectl get secret -n kube-system kube-apiserver -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)
    if [ -n "$api_cert" ]; then
        k8s_check_cert "kube-apiserver" "$(k8s_cert_days_until_expiry "$api_cert")" || K8S_HEALTH_CERT_ERROR=1
    else
        local api_pod
        api_pod=$(k8s_health_kubectl get pods -n kube-system -l component=kube-apiserver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
        if [ -n "$api_pod" ]; then
            k8s_check_cert "kube-apiserver (pod running)" 90 || K8S_HEALTH_CERT_ERROR=1
        else
            echo -e "${K8S_HEALTH_YELLOW}  ⚠ API server cert/secret not found${K8S_HEALTH_RESET}"
        fi
    fi

    # etcd - på Talos finns inga kube-system-secrets för etcd; certen ligger i
    # /system/secrets på noden och roteras av Talos. Ett "secret not found" är
    # därför inte ett problem och ska inte sätta cert-felet.
    echo -e "${K8S_HEALTH_YELLOW}  etcd Peer Certificate...${K8S_HEALTH_RESET}"
    local etcd_cert
    etcd_cert=$(k8s_health_kubectl get secret -n kube-system kube-etcd -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)
    if [ -n "$etcd_cert" ]; then
        k8s_check_cert "kube-etcd" "$(k8s_cert_days_until_expiry "$etcd_cert")" || K8S_HEALTH_CERT_ERROR=1
    else
        echo -e "${K8S_HEALTH_BLUE}  ℹ etcd-certaten hanteras av Talos (/system/secrets) och roteras automatiskt${K8S_HEALTH_RESET}"
    fi

    # Kubelet serving certificates - samma sak: på Talos finns de inte som
    # Kubernetes-secrets utan som nodcertifikat i /system/secrets/kubelet.
    echo -e "${K8S_HEALTH_YELLOW}  Kubelet Serving Certificates...${K8S_HEALTH_RESET}"
    local kubelet_failed=0 kubelet_checked=0 kubelet_missing=0
    for node in $(k8s_health_kubectl get nodes -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local kubelet_cert
        kubelet_cert=$(k8s_health_kubectl get secret -n kube-system "kubelet-serving-$node" -o jsonpath='{.data.tls\.crt}' 2>/dev/null | base64 -d)
        if [ -n "$kubelet_cert" ]; then
            k8s_check_cert "kubelet-serving ($node)" "$(k8s_cert_days_until_expiry "$kubelet_cert")" || kubelet_failed=1
            kubelet_checked=$((kubelet_checked + 1))
        else
            kubelet_missing=$((kubelet_missing + 1))
        fi
    done
    if [ "$kubelet_checked" -gt 0 ]; then
        [ "$kubelet_missing" -gt 0 ] && \
            echo -e "${K8S_HEALTH_BLUE}  ℹ $kubelet_missing kubelet-serving-cert saknas som secret (Talos-hanterat)${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_BLUE}  ℹ kubelet-serving-cert hanteras av Talos (/system/secrets/kubelet) och roteras automatiskt${K8S_HEALTH_RESET}"
    fi
    [ $kubelet_failed -eq 1 ] && K8S_HEALTH_CERT_ERROR=1

    # Service Account Tokens
    echo -e "${K8S_HEALTH_YELLOW}  Service Account Tokens...${K8S_HEALTH_RESET}"
    local sa_tokens
    sa_tokens=$(k8s_health_kubectl get secrets -A -o json 2>/dev/null)
    if [ -z "$sa_tokens" ]; then
        echo -e "${K8S_HEALTH_YELLOW}  ⚠ Kan inte hämta secrets${K8S_HEALTH_RESET}"
    else
        local sa_warnings=0 ns name expiry expiry_epoch days
        while IFS='/' read -r ns name; do
            [ -z "$ns" ] || [ -z "$name" ] && continue
            expiry=$(k8s_health_kubectl get secret "$name" -n "$ns" -o jsonpath='{.metadata.annotations.kubernetes\.io/expires-at}' 2>/dev/null)
            [ -z "$expiry" ] && expiry=$(k8s_health_kubectl get secret "$name" -n "$ns" -o jsonpath='{.metadata.annotations.expiration}' 2>/dev/null)
            [ -z "$expiry" ] || [ "$expiry" = "null" ] && continue

            expiry_epoch=$(date -d "$expiry" +%s 2>/dev/null) || continue
            [ "$expiry_epoch" -le 0 ] && continue

            days=$(( (expiry_epoch - $(date +%s)) / 86400 ))
            if [ "$days" -lt 0 ]; then
                echo -e "${K8S_HEALTH_RED}  ✗ $ns/$name: EXPIRED${K8S_HEALTH_RESET}"
                sa_warnings=1
            elif [ "$days" -lt 30 ]; then
                echo -e "${K8S_HEALTH_YELLOW}  ⚠ $ns/$name: expires in $days days${K8S_HEALTH_RESET}"
                sa_warnings=1
            fi
        done < <(echo "$sa_tokens" | jq -r '
            .items[]
            | select(.type == "kubernetes.io/service-account-token")
            | "\(.metadata.namespace)/\(.metadata.name)"
        ' 2>/dev/null)
        [ $sa_warnings -eq 0 ] && echo -e "${K8S_HEALTH_GREEN}  ✓ Inga expirerande tokens${K8S_HEALTH_RESET}"
    fi

    [ $K8S_HEALTH_CERT_ERROR -eq 1 ] && \
        k8s_health_error "Certifikatproblem hittade - se lista med fel och varningar ovan"
}

# =============================================================================
# Longhorn Storage
# =============================================================================

k8s_health_check_longhorn() {
    k8s_health_section "Longhorn status..."

    if ! k8s_health_has_crd volumes.longhorn.io; then
        k8s_health_info "Longhorn är inte installerat"
        return 0
    fi

    local volumes healthy degraded faulted attached detached
    volumes=$(k8s_health_kubectl get volumes -n longhorn-system --no-headers 2>/dev/null)

    # Count without the "grep -c || echo 0" bug (grep -c already prints 0)
    healthy=$(echo "$volumes" | awk '{print $4}' | grep -c '^healthy$')
    degraded=$(echo "$volumes" | awk '{print $4}' | grep -c '^degraded$')
    faulted=$(echo "$volumes" | awk '{print $4}' | grep -c '^faulted$')
    attached=$(echo "$volumes" | awk '{print $3}' | grep -c '^attached$')
    detached=$(echo "$volumes" | awk '{print $3}' | grep -c '^detached$')

    echo "Volumes:"
    echo -e "${K8S_HEALTH_GREEN}  Healthy: $healthy${K8S_HEALTH_RESET}"
    [ "$degraded" -gt 0 ] && echo -e "${K8S_HEALTH_YELLOW}  Degraded: $degraded${K8S_HEALTH_RESET}" || echo -e "${K8S_HEALTH_GREEN}  Degraded: $degraded${K8S_HEALTH_RESET}"
    [ "$faulted" -gt 0 ] && echo -e "${K8S_HEALTH_RED}  Fault: $faulted${K8S_HEALTH_RESET}" || echo -e "${K8S_HEALTH_GREEN}  Fault: $faulted${K8S_HEALTH_RESET}"
    [ "$detached" -gt 0 ] && echo -e "${K8S_HEALTH_YELLOW}  Detached: $detached${K8S_HEALTH_RESET}" || echo -e "${K8S_HEALTH_GREEN}  Detached: $detached${K8S_HEALTH_RESET}"

    echo "Nodes:"
    local unschedulable=0

    if k8s_health_kubectl get nodes.longhorn.io -n longhorn-system >/dev/null 2>&1; then
        for node in $(k8s_health_kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
            local schedulable=0 total=0 disk_status
            disk_status=$(k8s_health_kubectl get nodes.longhorn.io "$node" -n longhorn-system -o jsonpath='{.status.diskStatus}' 2>/dev/null)

            if [ -n "$disk_status" ] && [ "$disk_status" != "null" ]; then
                for disk in $(echo "$disk_status" | jq -r 'keys[]' 2>/dev/null); do
                    total=$((total + 1))
                    local can_schedule
                    can_schedule=$(echo "$disk_status" | jq -r ".[\"$disk\"].conditions[]? | select(.type == \"Schedulable\") | .status" 2>/dev/null)
                    [ "$can_schedule" = "True" ] && schedulable=$((schedulable + 1))
                done
            fi

            if [ "$schedulable" -eq "$total" ] && [ "$total" -gt 0 ]; then
                echo -e "${K8S_HEALTH_GREEN}  $node: $schedulable/$total diskar schedulable${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_YELLOW}  $node: $schedulable/$total diskar schedulable${K8S_HEALTH_RESET}"
                unschedulable=$((unschedulable + 1))
            fi
        done
    else
        k8s_health_error "Kan inte hämta Longhorn-nodes"
    fi

    if [ "$faulted" -gt 0 ] || [ "$detached" -gt 0 ] || [ "$unschedulable" -gt 0 ]; then
        k8s_health_error "Det finns problem med Longhorn (faulted=$faulted, detached=$detached, unschedulable=$unschedulable)"
        k8s_health_suggest "simon kubernetes longhorn repair"
    fi
}

# =============================================================================
# Cert Manager
# =============================================================================

k8s_health_check_cert_manager() {
    k8s_health_section "Cert Manager..."

    if ! k8s_health_has_crd certificates.cert-manager.io; then
        k8s_health_info "cert-manager är inte installerat"
        return 0
    fi

    local ns="cert-manager" has_error=0

    echo -e "${K8S_HEALTH_YELLOW}  Poddar...${K8S_HEALTH_RESET}"
    while IFS= read -r line; do
        [ -z "$line" ] && continue
        local ready_status ready_num running
        ready_status=$(echo "$line" | awk '{print $2}')
        ready_num=$(echo "$ready_status" | cut -d'/' -f1)
        running=$(echo "$ready_status" | cut -d'/' -f2)

        if [[ "$line" == *"Running"* ]] || [[ "$line" == *"Completed"* ]]; then
            [ "$ready_num" -eq "$running" ] 2>/dev/null && \
                echo -e "${K8S_HEALTH_GREEN}  ✓ $line${K8S_HEALTH_RESET}" || \
                echo -e "${K8S_HEALTH_YELLOW}  ⚠ $line ($ready_status)${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $line ($ready_status)${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done < <(k8s_health_kubectl get pods -n "$ns" --no-headers 2>/dev/null)

    echo -e "${K8S_HEALTH_YELLOW}  ClusterIssuers...${K8S_HEALTH_RESET}"
    while IFS= read -r issuer_line; do
        [ -z "$issuer_line" ] && continue
        [[ "$issuer_line" == NAME* ]] && continue

        local issuer_name condition
        issuer_name=$(echo "$issuer_line" | awk '{print $1}')
        condition=$(echo "$issuer_line" | awk '{print $2}')

        if [ "$condition" = "True" ] || [ "$condition" = "Ready" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $issuer_name: Ready${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $issuer_name: $condition${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done < <(k8s_health_kubectl get clusterissuer 2>/dev/null)

    echo -e "${K8S_HEALTH_YELLOW}  Certificates...${K8S_HEALTH_RESET}"
    while IFS= read -r cert_line; do
        [ -z "$cert_line" ] && continue
        [[ "$cert_line" == NAMESPACE* ]] && continue

        local cert_name namespace condition
        namespace=$(echo "$cert_line" | awk '{print $1}')
        cert_name=$(echo "$cert_line" | awk '{print $2}')
        condition=$(echo "$cert_line" | awk '{print $3}')

        if [ "$condition" = "Ready" ] || [ "$condition" = "True" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $namespace/$cert_name: Ready${K8S_HEALTH_RESET}"
        else
            local reason
            reason=$(k8s_health_kubectl get certificate "$cert_name" -n "$namespace" -o jsonpath='{.status.conditions[0].reason}' 2>/dev/null)
            echo -e "${K8S_HEALTH_RED}  ✗ $namespace/$cert_name: $condition ($reason)${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done < <(k8s_health_kubectl get certificate --all-namespaces 2>/dev/null)

    echo -e "${K8S_HEALTH_YELLOW}  Orders (ACME)...${K8S_HEALTH_RESET}"
    local order_count
    order_count=$(k8s_health_kubectl get orders -n cert-manager --no-headers 2>/dev/null | grep -c .)
    if [ "$order_count" -gt 0 ]; then
        while IFS= read -r order_line; do
            [ -z "$order_line" ] && continue
            local order_name state
            order_name=$(echo "$order_line" | awk '{print $1}')
            state=$(echo "$order_line" | awk '{print $2}')
            if [ "$state" = "valid" ]; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ $order_name: $state${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_YELLOW}  ⚠ $order_name: $state${K8S_HEALTH_RESET}"
                has_error=1
            fi
        done < <(k8s_health_kubectl get orders -n cert-manager --no-headers 2>/dev/null)
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga order${K8S_HEALTH_RESET}"
    fi

    echo -e "${K8S_HEALTH_YELLOW}  Challenges (ACME)...${K8S_HEALTH_RESET}"
    local challenge_count
    challenge_count=$(k8s_health_kubectl get challenges -n cert-manager --no-headers 2>/dev/null | grep -c .)
    if [ "$challenge_count" -gt 0 ]; then
        while IFS= read -r challenge_line; do
            [ -z "$challenge_line" ] && continue
            [[ "$challenge_line" == NAME* ]] && continue

            local name state reason
            name=$(echo "$challenge_line" | awk '{print $1}')
            state=$(echo "$challenge_line" | awk '{print $2}')
            reason=$(k8s_health_kubectl get challenges -n cert-manager "$name" -o jsonpath='{.status.reason}' 2>/dev/null)

            if [ "$state" = "valid" ] || [ "$state" = "processing" ]; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ $name: $state${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_RED}  ✗ $name: $state ($reason)${K8S_HEALTH_RESET}"
                has_error=1
            fi
        done < <(k8s_health_kubectl get challenges -n cert-manager --no-headers 2>/dev/null)
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga challenges${K8S_HEALTH_RESET}"
    fi

    [ $has_error -eq 1 ] && k8s_health_error "Cert Manager har problem"
}

# =============================================================================
# Gateway API
# =============================================================================

k8s_health_check_gateway_api() {
    k8s_health_section "Envoy + Gateway API..."

    if ! k8s_health_has_crd gateways.gateway.networking.k8s.io; then
        k8s_health_info "Gateway API CRDs finns inte (Gateway API är inte installerat)"
        return 0
    fi

    local ns="envoy" has_error=0

    echo -e "${K8S_HEALTH_YELLOW}  Gateway API CRDs...${K8S_HEALTH_RESET}"
    for crd in "gatewayclasses.gateway.networking.k8s.io" "gateways.gateway.networking.k8s.io" "httproutes.gateway.networking.k8s.io"; do
        local crd_status
        crd_status=$(k8s_health_kubectl get crd "$crd" -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
        if [ "$crd_status" = "True" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $crd Established${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $crd not Established${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done

    echo -e "${K8S_HEALTH_YELLOW}  GatewayClasses...${K8S_HEALTH_RESET}"
    local gc
    for gc in $(k8s_health_kubectl get gatewayclass -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
        local gc_status
        gc_status=$(k8s_health_kubectl get gatewayclass "$gc" -o jsonpath='{.status.conditions[?(@.type=="Accepted")].status}' 2>/dev/null)
        if [ "$gc_status" = "True" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $gc: Accepted${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $gc: not Accepted${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done

    echo -e "${K8S_HEALTH_YELLOW}  Gateways...${K8S_HEALTH_RESET}"
    for gw in $(k8s_health_kubectl get gateways.gateway.networking.k8s.io -A -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null); do
        local gw_ns gw_name gw_status
        gw_ns="${gw%%/*}"
        gw_name="${gw##*/}"
        gw_status=$(k8s_health_kubectl get gateway "$gw_name" -n "$gw_ns" -o jsonpath='{.status.conditions[?(@.type=="Programmed")].status}' 2>/dev/null)
        if [ "$gw_status" = "True" ]; then
            echo -e "${K8S_HEALTH_GREEN}  ✓ $gw_ns/$gw_name: Programmed${K8S_HEALTH_RESET}"
        else
            echo -e "${K8S_HEALTH_RED}  ✗ $gw_ns/$gw_name: not Programmed${K8S_HEALTH_RESET}"
            has_error=1
        fi
    done

    echo -e "${K8S_HEALTH_YELLOW}  Envoy pods...${K8S_HEALTH_RESET}"
    if k8s_health_has_ns "$ns"; then
        while IFS= read -r pod_line; do
            [ -z "$pod_line" ] && continue
            if [[ "$pod_line" == *"Running"* ]]; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ $pod_line${K8S_HEALTH_RESET}"
            else
                echo -e "${K8S_HEALTH_RED}  ✗ $pod_line${K8S_HEALTH_RESET}"
                has_error=1
            fi
        done < <(k8s_health_kubectl get pods -n "$ns" --no-headers 2>/dev/null)
    else
        echo -e "${K8S_HEALTH_YELLOW}  ⚠ namespace $ns finns inte${K8S_HEALTH_RESET}"
    fi

    [ $has_error -eq 1 ] && k8s_health_error "Envoy/Gateway API har problem"
}

# =============================================================================
# Talos services
# =============================================================================

k8s_health_check_talos_services() {
    k8s_health_section "Talos-tjänster..."

    local name ip role
    local checked=0
    while IFS=$'\t' read -r name ip role; do
        [ -z "$name" ] && continue
        [ "$name" = "null" ] && continue
        # Only nodes we can actually talk to
        k8s_health_talosctl_quick version --nodes "$ip" >/dev/null 2>&1 || continue

        checked=$((checked + 1))
        local services_output
        services_output=$(k8s_health_talosctl services --nodes "$ip" 2>/dev/null)
        if [ -z "$services_output" ]; then
            echo -e "${K8S_HEALTH_YELLOW}  ⚠ $name: kunde inte hämta tjänster${K8S_HEALTH_RESET}"
            continue
        fi

        local unhealthy
        # HEALTH "?" betyder "ingen health check" - det är inte ett fel
        unhealthy=$(echo "$services_output" | awk 'NR>1 && NF>3 && ($3 != "Running" || ($4 != "OK" && $4 != "?")) {print $2": "$3"/"$4}')
        if [ -n "$unhealthy" ]; then
            echo "$unhealthy" | while IFS= read -r svc; do
                [ -z "$svc" ] && continue
                echo -e "${K8S_HEALTH_RED}  ✗ $name → $svc${K8S_HEALTH_RESET}"
            done
            k8s_health_error "Talos-tjänster med problem på $name"
        else
            echo -e "${K8S_HEALTH_GREEN}  ✓ $name: alla tjänster OK${K8S_HEALTH_RESET}"
        fi

        # Disk usage on the node
        local usage
        usage=$(k8s_health_talosctl df --nodes "$ip" 2>/dev/null | awk 'NR>1 {printf "%s %s", $6, $7}')
        [ -n "$usage" ] && echo -e "${K8S_HEALTH_YELLOW}    disk: $usage${K8S_HEALTH_RESET}"
    done < <(k8s_health_node_list)

    [ "$checked" -eq 0 ] && k8s_health_info "Inga noder nåbara via Talos API - hoppar över"
}

# =============================================================================
# iSCSI
# =============================================================================

k8s_health_check_iscsi() {
    k8s_health_section "iSCSI Status..."

    if k8s_health_has_ns iscsi-drivers; then
        k8s_health_kubectl get all -n iscsi-drivers 2>/dev/null
        return
    fi

    if k8s_health_has_ns kubevirt; then
        k8s_health_kubectl get all -n kubevirt 2>/dev/null
        return
    fi

    # Utan iscsi-drivers och kubevirt är ext-iscsid inte relevant - den
    # snoddar då "NoResponse" på varje nod utan att det betyder något.
    echo -e "${K8S_HEALTH_BLUE}  ℹ Varken iscsi-drivers eller kubevirt är installerat - ext-iscsid kontrolleras inte${K8S_HEALTH_RESET}"
}

# =============================================================================
# Auto-remediation (--fix)
# =============================================================================

k8s_health_fix() {
    k8s_health_section "Auto-fix..."

    local fixed=0

    # 1. Approve pending CSRs
    local pending_csrs
    pending_csrs=$(k8s_health_kubectl get csr --no-headers 2>/dev/null | awk '$2 == "Pending" {print $1}')
    if [ -n "$pending_csrs" ]; then
        while IFS= read -r csr; do
            [ -z "$csr" ] && continue
            if k8s_health_kubectl certificate approve "$csr" >/dev/null 2>&1; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ Godkände CSR $csr${K8S_HEALTH_RESET}"
                fixed=$((fixed + 1))
            else
                echo -e "${K8S_HEALTH_RED}  ✗ Kunde inte godkänna CSR $csr${K8S_HEALTH_RESET}"
            fi
        done <<<"$pending_csrs"
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga pending CSR att godkänna${K8S_HEALTH_RESET}"
    fi

    # 2. Remove finalizers from pods stuck in Terminating
    local stuck
    stuck=$(k8s_health_kubectl get pods -A -o json 2>/dev/null | jq -r '
        .items[]
        | select(.metadata.deletionTimestamp != null)
        | select(.status.phase == "Running" or .status.phase == "Pending")
        | "\(.metadata.namespace) \(.metadata.name)"
    ' 2>/dev/null)
    if [ -n "$stuck" ]; then
        while read -r ns name; do
            [ -z "$ns" ] || [ -z "$name" ] && continue
            if k8s_health_kubectl patch pod "$name" -n "$ns" -p '{"metadata":{"finalizers":null}}' --type=merge >/dev/null 2>&1; then
                echo -e "${K8S_HEALTH_GREEN}  ✓ Tog bort finalizers från pod $ns/$name${K8S_HEALTH_RESET}"
                fixed=$((fixed + 1))
            fi
        done <<<"$stuck"
    else
        echo -e "${K8S_HEALTH_GREEN}  ✓ Inga poddar fast i Terminating${K8S_HEALTH_RESET}"
    fi

    # 3. Restart unhealthy Flux controllers
    if k8s_health_has_ns flux-system; then
        local bad_flux
        bad_flux=$(k8s_health_kubectl get pods -n flux-system --no-headers 2>/dev/null | awk '$3 !~ /Running|Completed/ {print $1}')
        if [ -n "$bad_flux" ]; then
            while IFS= read -r pod; do
                [ -z "$pod" ] && continue
                k8s_health_kubectl delete pod "$pod" -n flux-system >/dev/null 2>&1 && \
                    echo -e "${K8S_HEALTH_GREEN}  ✓ Startade om Flux-pod $pod${K8S_HEALTH_RESET}" && fixed=$((fixed + 1))
            done <<<"$bad_flux"
        else
            echo -e "${K8S_HEALTH_GREEN}  ✓ Flux controllers är friska${K8S_HEALTH_RESET}"
        fi
    fi

    # 4. Force reconcile of flux resources
    if command -v flux >/dev/null 2>&1 && k8s_health_has_ns flux-system; then
        k8s_health_flux reconcile kustomization --all --with-source >/dev/null 2>&1 && \
            echo -e "${K8S_HEALTH_GREEN}  ✓ Reconcilade alla Kustomizations${K8S_HEALTH_RESET}"
    fi

    echo ""
    if [ "$fixed" -eq 0 ]; then
        echo -e "${K8S_HEALTH_BLUE}  Inga åtgärder behövdes${K8S_HEALTH_RESET}"
    else
        echo -e "${K8S_HEALTH_GREEN}  $fixed åtgärder genomförda${K8S_HEALTH_RESET}"
    fi
}

# =============================================================================
# Main Orchestrator
# =============================================================================

main_kubernetes_health() {
    local mode="relaxed"
    local explicit_context=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --strict) mode="strict" ;;
            --context) shift; explicit_context="${1:-}" ;;
            --context=*) explicit_context="${1#--context=}" ;;
            --fix) K8S_HEALTH_FIX=1 ;;
            --quick) K8S_HEALTH_QUICK=1 ;;
            -h|--help)
                echo "Usage: simon cluster health [options]"
                echo ""
                echo "Options:"
                echo "  --strict           Fail when any check reports an error"
                echo "  --context <ctx>    Kubernetes context to check (default: auto-detect)"
                echo "  --fix              Try to auto-remediate common problems"
                echo "  --quick            Skip slow checks"
                return 0
                ;;
            *) echo "Unknown option: $1" >&2; return 1 ;;
        esac
        shift
    done

    # Initialize globals
    K8S_HEALTH_MODE="$mode"
    K8S_HEALTH_ERRORS=()
    K8S_HEALTH_WARNINGS=()
    K8S_HEALTH_SUGGESTIONS=()
    K8S_HEALTH_CERT_ERROR=0

    echo "🔍 Cluster Health Check"
    echo "======================="
    if [ "$mode" = "strict" ]; then
        echo "Mode: STRICT (fail when any check reports an error)"
    else
        echo "Mode: RELAXED (continue on errors, summarize at end)"
    fi
    echo ""

    k8s_health_check_tools
    [ ${#K8S_HEALTH_ERRORS[@]} -gt 0 ] && [ "$mode" = "strict" ] && return 1

    k8s_health_resolve_context "$explicit_context"
    k8s_health_check_context
    [ ${#K8S_HEALTH_ERRORS[@]} -gt 0 ] && [ "$mode" = "strict" ] && return 1

    k8s_health_check_node_inventory
    k8s_health_check_talos_certs
    k8s_health_check_talos_api
    k8s_health_check_talos_health
    k8s_health_check_etcd

    k8s_health_check_k8s_nodes
    k8s_health_check_node_conditions
    k8s_health_check_node_resources
    k8s_health_check_pods
    k8s_health_check_kube_system
    k8s_health_check_storage
    k8s_health_check_dns
    k8s_health_check_network
    [ "$K8S_HEALTH_QUICK" -eq 0 ] && k8s_health_check_events

    k8s_health_check_flux_pods
    k8s_health_check_flux_kustomizations
    k8s_health_check_flux_sources
    k8s_health_check_helmreleases
    k8s_health_check_csrs
    k8s_health_check_csr_approver
    k8s_health_check_longhorn
    k8s_health_check_cert_manager
    k8s_health_check_certificates
    k8s_health_check_gateway_api

    if [ "$K8S_HEALTH_QUICK" -eq 0 ]; then
        k8s_health_check_talos_services
    fi
    k8s_health_check_iscsi

    # Call external health functions if they exist.
    # main_kubernetes_iscsi_health kontrollerar ext-iscsid på varje nod - det
    # är bara relevant om kubevirt/iscsi-drivers faktiskt används, annars
    # rapporterar det "NoResponse" på varje nod utan betydelse.
    type main_kubernetes_versions >/dev/null 2>&1 && main_kubernetes_versions
    if type main_kubernetes_iscsi_health >/dev/null 2>&1; then
        if k8s_health_has_ns iscsi-drivers || k8s_health_has_ns kubevirt; then
            main_kubernetes_iscsi_health
        else
            k8s_health_info "ext-iscsid hoppas över (varken kubevirt eller iscsi-drivers är installerat)"
        fi
    fi

    if [ "$K8S_HEALTH_FIX" -eq 1 ]; then
        k8s_health_fix
    fi

    # Summary
    echo ""
    if [ ${#K8S_HEALTH_WARNINGS[@]} -gt 0 ]; then
        echo -e "${K8S_HEALTH_YELLOW}⚠ Varningar: ${#K8S_HEALTH_WARNINGS[@]}${K8S_HEALTH_RESET}"
        for warn in "${K8S_HEALTH_WARNINGS[@]}"; do
            echo -e "${K8S_HEALTH_YELLOW}• $warn${K8S_HEALTH_RESET}"
        done
        echo ""
    fi

    if [ ${#K8S_HEALTH_ERRORS[@]} -gt 0 ]; then
        echo -e "${K8S_HEALTH_RED}❌ Health check failures: ${#K8S_HEALTH_ERRORS[@]}${K8S_HEALTH_RESET}"
        for err in "${K8S_HEALTH_ERRORS[@]}"; do
            echo -e "${K8S_HEALTH_RED}• $err${K8S_HEALTH_RESET}"
        done

        if [ ${#K8S_HEALTH_SUGGESTIONS[@]} -gt 0 ]; then
            echo ""
            echo -e "${K8S_HEALTH_YELLOW}💡 Föreslagna åtgärder:${K8S_HEALTH_RESET}"
            for sug in "${K8S_HEALTH_SUGGESTIONS[@]}"; do
                echo -e "${K8S_HEALTH_YELLOW}→ $sug${K8S_HEALTH_RESET}"
            done
        fi
        return 1
    fi

    echo -e "${K8S_HEALTH_GREEN}✅ Alla health checks klar!${K8S_HEALTH_RESET}"
    return 0
}
