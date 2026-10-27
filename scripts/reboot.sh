#!/bin/bash

# ---------------------------------------------------------------------------
# Reboot: starta om Talos-noder via talosctl.
#
# Modulen är uppdelad i små funktioner med ett ansvar vardera.
# reboot_command orchestrerar dem och innehåller ingen affärslogik.
#
#   reboot_command              dispatcher (nod / all / list / poe)
#   reboot_node_command         reboot av en enskild nod
#   reboot_list_nodes           lista noder från nodes.yaml
#   reboot_usage                hjälptxt för kommandot
#   reboot_error/info/ok        presentationshjälpare
#   reboot_nodes_yaml           sökväg till nodes.yaml
#   reboot_is_ip                ser värdet ut som en IPv4-adress
#   reboot_node_ip              nodnamn -> IP ur nodes.yaml
#   reboot_node_names           lista nodnamn ur nodes.yaml
#   reboot_parse_args           dela upp mål och flaggor
#   reboot_talos_flags           egna flaggor -> talosctl-flaggor
#
# Reboot av en nod:
#   simon reboot controlplane-1
#   simon reboot controlplane-1 --drain
#   simon reboot 10.10.10.11 --force
#
# Övriga lägen:
#   simon reboot all            reboot av alla noder
#   simon reboot list           lista noder
#   simon reboot poe            PoE-cykel via UniFi (fzf-meny)
#   simon reboot                PoE-cykel via UniFi (fzf-meny)
# ---------------------------------------------------------------------------

# Delimiter mellan mål och flaggor. Inte tab: bash räknar tab som
# IFS-whitespace och kollapsar tomma fält.
REBOOT_FIELD_SEP="|"

# --- presentationshjälpare -------------------------------------------------

reboot_error() {
    echo -e "\033[31m❌ $1\033[0m" >&2
}

reboot_info() {
    echo -e "\033[34mℹ️  $1\033[0m"
}

reboot_ok() {
    echo -e "\033[32m✅ $1\033[0m"
}

# --- rena funktioner --------------------------------------------------------

# Sökväg till nodes.yaml. REBOOT_NODES_YAML används av testerna.
reboot_nodes_yaml() {
    if [ -n "${REBOOT_NODES_YAML:-}" ]; then
        printf '%s\n' "$REBOOT_NODES_YAML"
        return 0
    fi

    local repo
    repo=$(resolve_talos_infrastructure_repo) || return 1
    printf '%s\n' "$repo/talos/nodes.yaml"
}

# Ser värdet ut som en IPv4-adress?
reboot_is_ip() {
    local value="$1"
    [[ "$value" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

# Nodnamn -> IP. Tomt utskrift och felstatus om noden inte finns.
reboot_node_ip() {
    local name="$1" nodes_file="${2:-}" yq_bin ip

    [ -n "$name" ] || return 1
    [ -n "$nodes_file" ] || nodes_file=$(reboot_nodes_yaml) || return 1
    [ -f "$nodes_file" ] || return 1

    yq_bin=$(resolve_yq) || return 1
    ip=$("$yq_bin" -r ".nodes[] | select(.name == \"$name\") | .ip" "$nodes_file" 2>/dev/null | head -1)

    [ -n "$ip" ] && [ "$ip" != "null" ] || return 1
    printf '%s\n' "$ip"
}

# Alla nodnamn, en per rad.
reboot_node_names() {
    local nodes_file="${1:-}" yq_bin

    [ -n "$nodes_file" ] || nodes_file=$(reboot_nodes_yaml) || return 1
    [ -f "$nodes_file" ] || return 1

    yq_bin=$(resolve_yq) || return 1
    "$yq_bin" -r ".nodes[].name" "$nodes_file" 2>/dev/null
}

# Dela upp argumenten i mål och flaggor: "mål|flaggor".
# Flaggor behåller sina egna utrymmen, så de måste citeras vid användning.
reboot_parse_args() {
    local target="" flags=""

    while [ $# -gt 0 ]; do
        case "$1" in
            --*)
                flags="${flags:+$flags }$1"
                ;;
            *)
                if [ -z "$target" ]; then
                    target="$1"
                else
                    flags="${flags:+$flags }$1"
                fi
                ;;
        esac
        shift
    done

    printf '%s%s%s\n' "$target" "$REBOOT_FIELD_SEP" "$flags"
}

# Egna flaggor -> talosctl-flaggor.
#   --force       tvingad omstart (skippar kexec)
#   --powercycle  omstart via strömbrytaren
#   --drain       töm Kubernetes-noden först (cordon + evict)
#   --no-wait     vänta inte på att noden är tillbaka
reboot_talos_flags() {
    local out="" flag

    for flag in "$@"; do
        case "$flag" in
            --force) out="${out:+$out }--mode force" ;;
            --powercycle) out="${out:+$out }--mode powercycle" ;;
            --drain) out="${out:+$out }--drain" ;;
            --no-wait) out="${out:+$out }--wait=false" ;;
            *) reboot_error "Okänd flagga: $flag"; return 1 ;;
        esac
    done

    printf '%s\n' "$out"
}

# --- kommandon -------------------------------------------------------------

reboot_list_nodes() {
    local nodes_file yq_bin
    nodes_file=$(reboot_nodes_yaml) || return 1
    yq_bin=$(resolve_yq) || return 1

    echo -e "\033[34m📋 Noder i $nodes_file\033[0m"
    "$yq_bin" -r '.nodes[] | [.name, .ip, .role, (.poe | tostring)] | @tsv' "$nodes_file" 2>/dev/null |
        awk -F'\t' '{printf "  %-18s %-13s %-13s poe:%s\n", $1, $2, $3, $4}'
}

reboot_node_command() {
    local parsed target flags ip talos_flags

    parsed=$(reboot_parse_args "$@")
    target=$(printf '%s' "$parsed" | cut -d"$REBOOT_FIELD_SEP" -f1)
    flags=$(printf '%s' "$parsed" | cut -d"$REBOOT_FIELD_SEP" -f2-)

    if [ -z "$target" ]; then
        reboot_error "Ange en nod: simon reboot <nodnamn>"
        return 1
    fi

    if ! talos_flags=$(reboot_talos_flags $flags); then
        return 1
    fi

    if reboot_is_ip "$target"; then
        ip="$target"
    else
        if ! ip=$(reboot_node_ip "$target"); then
            reboot_error "Hittade inte noden '$target' i nodes.yaml"
            return 1
        fi
    fi

    echo -e "\033[34m🔄 Startar om $target ($ip)\033[0m"
    # shellcheck disable=SC2086 # flaggorna ska splittas på mellanslag
    talosctl reboot -n "$ip" $talos_flags
}

reboot_usage() {
    cat <<'HELP'
simon reboot - starta om noder och nätverksenheter

ANVÄNDNING
  simon reboot <nodnamn|ip> [flaggor]   Starta om en Talos-nod
  simon reboot all                       Starta om alla noder i klustret
  simon reboot list                      Visa noder med IP, roll och PoE-port
  simon reboot poe                       Starta om enheter via UniFi-PoE (fzf-meny)
  simon reboot                           Samma som "simon reboot poe"

NODER
  Nodnamnet slås upp i talos/nodes.yaml i infrastructure-repotet, så
  "simon reboot controlplane-1" räcker - du behöver inte IP:t. En IP-adress
  fungerar också direkt ("simon reboot 10.10.10.11").

  En omstart är graceful (kexec) om inget annat sägs: Talos startar om
  kerneln i farten och noden behåller sin konfiguration och sitt medlemskap
  i klustret.

FLAGGOR (för en nod)
  --drain                                Töm noden i Kubernetes först
                                         (cordon + evict pods) innan omstart
  --force                                Tvingad omstart, skippar kexec
  --powercycle                           Omstart via strömbrytaren, skippar kexec
  --no-wait                              Vänta inte på att noden är tillbaka

  --drain är bra vid underhåll: workload evakueras till andra noder innan
  noden startar om, så inga poddar blir avbrutna mitt i en deploy.

EXEMPEL
  simon reboot controlplane-1            Graceful omstart av controlplane-1
  simon reboot worker-1 --drain          Töm worker-1:s pods och starta om den
  simon reboot 10.10.10.11 --force       Tvingad omstart av noden med IP:t
  simon reboot all                       Starta om hela klustret

POE
  "simon reboot" och "simon reboot poe" öppnar en lista över portarna på
  switchen där du väljer enheter att strömsätta om. Det slår av PoE på
  valda portar och startar dem igen efter en stund - används när en enhet
  hänger sig och inte svarar.
HELP
}

reboot_command() {
    case "${1:-}" in
        "") main_reboot ;;
        poe) main_reboot ;;
        all) main_talos_reboot_all ;;
        list) reboot_list_nodes ;;
        --help|-h) reboot_usage ;;
        *) reboot_node_command "$@" ;;
    esac
}
