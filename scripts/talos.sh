#!/bin/bash

# Converted from talos.nu

export TALOSCONFIG="${TALOSCONFIG:-$HOME/.talos/config}"

# Funktion för att extrahera första YAML-dokumentet
# talosctl gen config genererar flera YAML-dokument (NDYAML), apply-config kräver ett enda
convert_ndjson_to_yaml() {
    local input_file="$1"
    local output_file="$2"
    
    if [ ! -f "$input_file" ]; then
        echo "   [convert] ❌ Input-fil finns inte: $input_file"
        return 1
    fi
    
    # Extrahera första dokumentet med awk (allt före första ---)
    # talosctl gen config genererar NDYAML med --- som dokumentavskiljare
    awk '/^---$/{exit} {print}' "$input_file" > "$output_file" 2>/dev/null
    
    if [ $? -eq 0 ] && [ -s "$output_file" ]; then
        return 0
    else
        echo "   [convert] ❌ awk misslyckades"
        return 1
    fi
}

resolve_talos_infrastructure_repo() {
    local configured_repo="${INFRA_REPO:-}"
    local current_repo

    if [ -n "$configured_repo" ]; then
        if [ -f "$configured_repo/talos/nodes.yaml" ]; then
            printf '%s\n' "$configured_repo"
            return 0
        fi
        echo "Infrastructure-repo saknas eller saknar talos/nodes.yaml: $configured_repo" >&2
        return 1
    fi

    current_repo=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [ -f "$current_repo/talos/nodes.yaml" ]; then
        printf '%s\n' "$current_repo"
        return 0
    fi

    if [ -f "$HOME/repos/infrastructure/talos/nodes.yaml" ]; then
        printf '%s\n' "$HOME/repos/infrastructure"
        return 0
    fi

    echo "Kunde inte hitta ett infrastructure-repo med talos/nodes.yaml" >&2
    return 1
}

# yq finns i två varianter på maskinen: mikefarah (Go) och kislyuk (jq-wrapper).
# Scripten är skriven för mikefarah - "/usr/bin/yq" är wrapper-versionen och
# kan inte tolka t.ex. ."talos-schematic-id" eller select(...). |= ...
# Resolv:a därför rätt variant först och använd den konsekvent.
SIMON_YQ=""
resolve_yq() {
    local candidate

    if [ -n "$SIMON_YQ" ]; then
        printf '%s\n' "$SIMON_YQ"
        return 0
    fi

    if command -v yq >/dev/null 2>&1 && yq --version 2>&1 | grep -q "mikefarah"; then
        SIMON_YQ=$(command -v yq)
    else
        for candidate in \
            /home/linuxbrew/.linuxbrew/bin/yq \
            /usr/local/bin/yq \
            /opt/homebrew/bin/yq; do
            if [ -x "$candidate" ] && "$candidate" --version 2>&1 | grep -q "mikefarah"; then
                SIMON_YQ="$candidate"
                break
            fi
        done
    fi

    if [ -z "$SIMON_YQ" ]; then
        echo "❌ yq (mikefarah) hittades inte. Installera med: brew install yq" >&2
        return 1
    fi

    printf '%s\n' "$SIMON_YQ"
}

# Extrahera maskinconfigens "spec" ur "talosctl get machineconfig -o yaml".
#
# Talos v1.14 returnerar specen som en quoted sträng ("spec: \"...\\n...\"") och
# inte som en YAML-block ("spec: |"). En awk som letar efter "spec: |" hittar
# ingenting, filen blir tom och varje nod rapporteras som "ingen användbar
# spec". yq avkodar båda formaten.
extract_machine_config_spec() {
    local raw_config_file="$1"
    local extracted_config_file="$2"
    local yq_bin="${SIMON_YQ:-}"

    [ -f "$raw_config_file" ] || return 1

    if [ -z "$yq_bin" ]; then
        yq_bin=$(resolve_yq) || return 1
    fi

    if ! "$yq_bin" eval-all 'select(documentIndex == 0) | .spec' "$raw_config_file" \
        > "$extracted_config_file" 2>/dev/null; then
        return 1
    fi

    [ -s "$extracted_config_file" ]
}

# Hitta nodens patch-fil. Layouten skiljer sig mellan roller:
#   worker:       patches/workers/<nod>/patch.yaml
#   controlplane: patches/controlplanes/<nod>.yaml
talos_node_patch_file() {
    local role="$1"
    local node_name="$2"
    local base_dir="$3"
    local candidate

    for candidate in "$base_dir/${role}s/$node_name/patch.yaml" "$base_dir/${role}s/$node_name.yaml"; do
        if [ -f "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done

    return 1
}

# Bygg en CEL-match för nodens installationsdisk.
#
# Två format stöds:
#   - v1alpha1: ett UnattendedInstallConfig-dokument med
#     provisioning.diskSelector.match (används direkt)
#   - legacy:   machine.install.diskSelector.serial/model/size, som översätts
#     till CEL med samma logik som pxe/generate-node-configs.py
talos_install_match() {
    local patch_file="$1"
    local yq_bin="${SIMON_YQ:-}"

    if [ -z "$yq_bin" ]; then
        yq_bin=$(resolve_yq) || return 1
    fi

    local match
    match=$("$yq_bin" eval-all \
        'select(.kind == "UnattendedInstallConfig") | .provisioning.diskSelector.match // ""' \
        "$patch_file" 2>/dev/null | head -1)
    if [ -n "$match" ] && [ "$match" != "null" ]; then
        printf '%s\n' "$match"
        return 0
    fi

    # v1alpha1-form i patch-filen: machine.provisioning.diskSelector.match
    match=$("$yq_bin" eval-all \
        'select(.kind == null) | .machine.provisioning.diskSelector.match // ""' \
        "$patch_file" 2>/dev/null | head -1)
    if [ -n "$match" ] && [ "$match" != "null" ]; then
        printf '%s\n' "$match"
        return 0
    fi

    local serial model size
    serial=$("$yq_bin" eval-all \
        'select(.kind == null) | .machine.install.diskSelector.serial // ""' \
        "$patch_file" 2>/dev/null | head -1)
    model=$("$yq_bin" eval-all \
        'select(.kind == null) | .machine.install.diskSelector.model // ""' \
        "$patch_file" 2>/dev/null | head -1)
    size=$("$yq_bin" eval-all \
        'select(.kind == null) | .machine.install.diskSelector.size // ""' \
        "$patch_file" 2>/dev/null | head -1)

    if [ -n "$serial" ] && [ "$serial" != "null" ]; then
        printf 'disk.serial == "%s"\n' "$serial"
        return 0
    fi

    if [ -n "$model" ] && [ "$model" != "null" ]; then
        local cel="disk.model == \"$model\""

        if [ -n "$size" ] && [ "$size" != "null" ]; then
            local operator="" value="$size"

            case "$size" in
                "<="*) operator="<="; value="${size#<= }" ;;
                ">="*) operator=">="; value="${size#>= }" ;;
                "<"*)  operator="<";  value="${size#< }" ;;
                ">"*)  operator=">";  value="${size#> }" ;;
                "=="*) operator="=="; value="${size#== }" ;;
            esac

            local number="${value%GB}"
            local bytes=$((number * 1024 * 1024 * 1024))
            cel="$cel && disk.size ${operator:-==} ${bytes}u"
        fi

        printf '%s\n' "$cel"
        return 0
    fi

    return 1
}

# Bygg ett UnattendedInstallConfig-dokument (v1alpha1).
talos_install_doc() {
    local match="$1"
    local image="$2"

    cat <<EOF
apiVersion: v1alpha1
kind: UnattendedInstallConfig
installer:
  image: $image
provisioning:
  diskSelector:
    match: '$match'
  wipe: false
EOF
}

# Bygg ett HostnameConfig-dokument (v1alpha1).
talos_hostname_doc() {
    printf 'apiVersion: v1alpha1\nkind: HostnameConfig\nhostname: "%s"\n' "$1"
}

# Normalisera en UserVolumeConfig till Talos v1.14.
#
# v1.14 kräver volumeType (annars krävs min/max-size, vilket skulle partitionera
# om en disk som redan har Longhorn-data) och stöder inte minSize/maxSize/grow.
talos_normalize_user_volume() {
    local in_file="$1"
    local out_file="$2"
    local yq_bin="${SIMON_YQ:-}"

    if [ -z "$yq_bin" ]; then
        yq_bin=$(resolve_yq) || return 1
    fi

    "$yq_bin" eval-all '
        select(.kind == "UserVolumeConfig") |
        .volumeType = "disk" |
        del(.minSize, .maxSize, .grow) |
        del(.provisioning.minSize, .provisioning.maxSize, .provisioning.grow)
    ' "$in_file" > "$out_file" 2>/dev/null || return 1

    [ -s "$out_file" ]
}

# Escapa en sträng för användning i ett yq-uttryck. mikefarah-yq har inga
# enkla citattecken - allt måste skrivas med dubbla citattecken.
yq_escape_string() {
    printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'
}

# Målversionen för klustret: repots egen deklaration (pxe/generate-node-configs.py).
# Den är sanningskällan - inte nodens nuvarande version, som kan vara äldre.
talos_target_version() {
    local infra_repo="$1"
    local version=""

    if [ -f "$infra_repo/pxe/generate-node-configs.py" ]; then
        version=$(grep -E '^[[:space:]]*TALOS_VERSION[[:space:]]*=' "$infra_repo/pxe/generate-node-configs.py" \
            | head -1 | sed -E 's/.*=[[:space:]]*["'"'"']?([^"'"'"']*)["'"'"']?.*/\1/')
    fi

    printf '%s\n' "$version"
}

# Serverns Talos-version (inte klientens) för en given nod.
talos_server_version() {
    talosctl --talosconfig "$1" version -n "$2" 2>/dev/null \
        | awk '/^Server:/{f=1} f && /Tag:/{print $2; exit}'
}

# Bygg nodens config utifrån referensnodens ALLA v1alpha1-dokument.
#
# Referensnodens config innehåller kluster-PKI, discovery-identity och
# kube-config - allt som behövs för att den nya noden ska joina samma kluster.
# Det som är nodspecifikt sätts om: machine.type, hostname och
# installationsdisken.
talos_build_node_config() {
    local reference_config="$1"
    local role="$2"
    local node_name="$3"
    local install_match="$4"
    local installer_image="$5"
    local reference_role="$6"
    local out_file="$7"
    local yq_bin="${SIMON_YQ:-}"

    if [ -z "$yq_bin" ]; then
        yq_bin=$(resolve_yq) || return 1
    fi

    cp "$reference_config" "$out_file" || return 1

    local role_e node_e image_e match_e
    role_e=$(yq_escape_string "$role")
    node_e=$(yq_escape_string "$node_name")
    image_e=$(yq_escape_string "$installer_image")
    match_e=$(yq_escape_string "$install_match")

    # machine.type sätts. machine.token kopieras från referensnoden - Talos
    # använder ett gemensamt maskin-token för hela klustret (det ligger i
    # secrets-bundlen), så det ska INTE randomiseras per nod.
    # machine.network/cluster.discovery finns inte i v1alpha1.
    "$yq_bin" eval-all "
        (select(.kind == null).machine.type) = \"$role_e\" |
        del(.cluster.discovery)
    " "$out_file" > "$out_file.tmp" 2>/dev/null || return 1
    mv "$out_file.tmp" "$out_file"

    # Hostname: nodens eget namn.
    "$yq_bin" eval-all "(select(.kind == \"HostnameConfig\").hostname) = \"$node_e\"" \
        "$out_file" > "$out_file.tmp" 2>/dev/null || return 1
    mv "$out_file.tmp" "$out_file"

    # Installationsdisk + installer image.
    "$yq_bin" eval-all "
        (select(.kind == \"UnattendedInstallConfig\").installer.image) = \"$image_e\" |
        (select(.kind == \"UnattendedInstallConfig\").provisioning.diskSelector.match) = \"$match_e\" |
        (select(.kind == \"UnattendedInstallConfig\").provisioning.wipe) = false
    " "$out_file" > "$out_file.tmp" 2>/dev/null || return 1
    mv "$out_file.tmp" "$out_file"

    # Om referensen är en controlplane men noden ska vara worker måste
    # controlplane-specifika dokument bort och den signerande CA-nyckeln
    # tömmas (Talos tillåter inte issuing-CA-nyckel på workers).
    #
    # select() används här istället för del() - del() tar bara bort den första
    # träffen, och det finns två KubeAuthorizerConfig-dokument.
    if [ "$role" = "worker" ] && [ "$reference_role" = "controlplane" ]; then
        "$yq_bin" eval-all '
            select(.kind != "KubeAPIServerConfig") |
            select(.kind != "KubeAdmissionControlConfig") |
            select(.kind != "KubeAggregatorCAConfig") |
            select(.kind != "KubeAuditPolicyConfig") |
            select(.kind != "KubeAuthenticationConfig") |
            select(.kind != "KubeAuthorizerConfig") |
            select(.kind != "KubeControllerManagerConfig") |
            select(.kind != "KubeCoreDNSConfig") |
            select(.kind != "KubeEtcdEncryptionConfig") |
            select(.kind != "KubeFlannelCNIConfig") |
            select(.kind != "KubeProxyConfig") |
            select(.kind != "KubeSchedulerConfig") |
            select(.kind != "KubeServiceAccountConfig")
        ' "$out_file" > "$out_file.tmp" 2>/dev/null || return 1
        mv "$out_file.tmp" "$out_file"

        "$yq_bin" eval-all '
            del(.cluster.etcd) |
            (select(.kind == null).machine.ca.key) = ""
        ' "$out_file" > "$out_file.tmp" 2>/dev/null || return 1
        mv "$out_file.tmp" "$out_file"
    fi

    # Om referensen saknar UnattendedInstallConfig lägger vi till ett.
    local install_docs
    install_docs=$("$yq_bin" eval-all 'select(.kind == "UnattendedInstallConfig") | .kind' "$out_file" 2>/dev/null | wc -l | tr -d ' ')
    if [ "$install_docs" -eq 0 ]; then
        talos_install_doc "$install_match" "$installer_image" >> "$out_file"
    fi

    [ -s "$out_file" ]
}

main_talos_dashboard() {
    ip="${1:-10.10.10.11}"
    
    # Get all nodes from config
    all_nodes=$(yq '.nodes[] | select(.initialized == true) | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml)
    
    # Test which nodes are reachable
    reachable_nodes=""
    for node in $all_nodes; do
        if timeout 2 talosctl -n "$node" version >/dev/null 2>&1; then
            reachable_nodes="${reachable_nodes}${node},"
        else
            echo "⚠️  Nod $node är inte tillgänglig, hoppar över..."
        fi
    done
    
    # Remove trailing comma
    nodesString="${reachable_nodes%,}"
    
    if [ -z "$nodesString" ]; then
        echo "❌ Inga noder är tillgängliga!"
        return 1
    fi
    
    echo "Ansluter till noder: $nodesString"
    talosctl dashboard -n "$nodesString"
}

main_talos_upgrade() {
    local target_node="${1:-}"
    local target_version="${2:-}"
    local target_login="${3:-}"
    local skip_cordon_drain="${4:-false}"

    if [ -n "$target_node" ]; then
        echo "Uppgraderar specifik nod: $target_node"
    fi

    if [ -z "$target_version" ]; then
        echo -e "\033[34mVilken version vill du installera?\033[0m"
        latestVersions=$(curl -s "https://api.github.com/repos/siderolabs/talos/releases?per_page=15" | jq -r '.[].tag_name')
        selectedVersion=$(fzfSelect "$latestVersions")
    else
        selectedVersion="$target_version"
        echo "Installerar version: $selectedVersion"
    fi

    if [ -z "$target_login" ]; then
        echo -e "\033[34mHur loggar du in mot klustret?\033[0m"
        loginMethods=("Teleport" "Certifikat")
        selectedMethod=$(fzfSelect "${loginMethods[@]}")
    else
        selectedMethod="$target_login"
        echo "Använder login-metod: $selectedMethod"
    fi

    if [ "$selectedMethod" = "Certifikat" ]; then
        nodes=$(kubectl get nodes --kubeconfig "$HOME/.config/simon/kubeconfig-certificate" | awk 'NR>1 {print $1}')
    else
        nodes=$(kubectl get nodes | awk 'NR>1 {print $1}')
    fi

    if [ -z "$target_node" ]; then
        echo -e "\033[34mVilka noder vill du uppdatera?\033[0m"
        selectedNodes=$(fzfSelect --multi "$nodes")
    else
        if echo "$nodes" | grep -qw "$target_node"; then
            selectedNodes="$target_node"
        else
            echo "❌ Noden $target_node hittades inte bland klustrets noder"
            return 1
        fi
    fi

    # Check for worker nodes
    local worker_nodes=()
    local controlplane_nodes=()
    for node in $selectedNodes; do
        local role
        role=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.role\.kubernetes\.io/role}' 2>/dev/null || echo "worker")
        if [ "$role" = "control-plane" ]; then
            controlplane_nodes+=("$node")
        else
            worker_nodes+=("$node")
        fi
    done

    # Pre-flight checks for worker nodes
    if [ ${#worker_nodes[@]} -gt 0 ]; then
        echo -e "\n\033[33m⚠️  Pre-flight kontroller för worker-noder...\033[0m"

        # Check PDBs
        echo "📋 Kontrollerar Pod Disruption Budgets..."
        local pdb_output
        pdb_output=$(kubectl get pdb --all-namespaces 2>&1)
        if echo "$pdb_output" | grep -q "No resources found"; then
            echo "  ⚠️  Inga PDBs konfigurerade!"
            echo "     Överväg att skapa PDBs för att skydda dina applikationer."
            if [ "$skip_cordon_drain" != "true" ]; then
                echo -n "   Fortsätt ändå? (y/N): "
                read -r confirm
                if [ "$confirm" != "y" ] && [ "$confirm" != "Y" ]; then
                    echo "Avbruten."
                    return 1
                fi
            fi
        else
            echo "$pdb_output"
        fi

        # Check cluster capacity
        echo "📋 Kontrollerar klusterkapacitet..."
        local ready_nodes
        ready_nodes=$(kubectl get nodes --no-headers 2>/dev/null | grep -c " Ready " || echo "0")
        echo "  Antal redo noder: $ready_nodes"
        echo "  Worker-noder som ska uppgraderas: ${#worker_nodes[@]}"

        if [ "$ready_nodes" -le ${#worker_nodes[@]} ]; then
            echo "❌ Fel: För få noder! Du måste ha minst 1 node kvar för att schemalägga pods."
            return 1
        fi

        # Check for pods with local PVs on worker nodes
        for node in "${worker_nodes[@]}"; do
            local pods_with_pv
            pods_with_pv=$(kubectl get pods --all-namespaces \
                --field-selector spec.nodeName="$node" \
                -o jsonpath='{range .items[*]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}' 2>/dev/null | \
                while IFS= read -r pod; do
                    kubectl get pod "$pod" -o jsonpath='{.spec.volumes[*].persistentVolumeClaim.claimName}' 2>/dev/null
                done | grep -v "^$" | wc -l)
            if [ "$pods_with_pv" -gt 0 ]; then
                echo "  ⚠️  Nod $node har $pods_with_pv pod(s) med persistent volumes"
                echo "     Dessa pods kan inte flyttas och kommer att vara nere tills noden är tillbaka."
            fi
        done
    fi

    # Upgrade each node with safe workflow
    local all_nodes=("${worker_nodes[@]}" "${controlplane_nodes[@]}")
    local upgrade_order=()

    # For workers, upgrade sequentially to maintain capacity
    # For controlplanes, also upgrade sequentially (no etcd cluster upgrades here)
    if [ ${#worker_nodes[@]} -gt 0 ]; then
        echo -e "\n\033[33m🔄 Worker-noder uppgraderas sekventiellt för att behålla klusterkapacitet...\033[0m"
        for node in "${worker_nodes[@]}"; do
            upgrade_order+=("$node")
        done
    fi

    if [ ${#controlplane_nodes[@]} -gt 0 ]; then
        echo -e "\n\033[33m🔄 Controlplane-noder:\033[0m"
        for node in "${controlplane_nodes[@]}"; do
            upgrade_order+=("$node")
        done
    fi

    # Perform upgrade with cordon/drain workflow
    for node in "${upgrade_order[@]}"; do
        local role
        role=$(kubectl get node "$node" -o jsonpath='{.metadata.labels.node\.role\.kubernetes\.io/role}' 2>/dev/null || echo "worker")
        local is_worker=false
        if [ "$role" != "control-plane" ]; then
            is_worker=true
        fi

        echo -e "\n\033[32m════════════════════════════════════════════════════════════\033[0m"
        echo "\033[32m🔄 Oppgraderar nod: $node ($role)\033[0m"
        echo "\033[32m════════════════════════════════════════════════════════════\033[0m"

        # Get node IP
        local node_ip
        node_ip=$(yq ".nodes[] | select(.name == \"$node\") | .ip" /home/simon/repos/infrastructure/talos/nodes.yaml 2>/dev/null | tr -d '"')
        if [ -z "$node_ip" ]; then
            echo "❌ Kunde inte hitta IP för nod $node"
            continue
        fi

        # Get schematic and arch
        local schematicID arch
        schematicID=$(yq ".nodes[] | select(.name == \"$node\") | .\"talos-schematic-id\"" /home/simon/repos/infrastructure/talos/nodes.yaml 2>/dev/null | head -1 | tr -d '"')
        arch=$(yq ".nodes[] | select(.name == \"$node\") | .\"arch\"" /home/simon/repos/infrastructure/talos/nodes.yaml 2>/dev/null | head -1 | tr -d '"')

        if [ -z "$schematicID" ]; then
            echo "❌ Fel: Kunde inte hämta talos-schematic-id för nod $node"
            continue
        fi

        echo "📝 Nod: $node | IP: $node_ip | Arch: $arch"
        echo "🔗 https://factory.talos.dev/image/$schematicID/$selectedVersion/metal-$arch.raw.xz"

        # Step 1: Cordon (for worker nodes to protect workloads)
        if [ "$is_worker" = true ] && [ "$skip_cordon_drain" != "true" ]; then
            echo -e "\n\033[34m📌 Steg 1: Cordon noden\033[0m"
            kubectl cordon "$node"
            echo "✅ Noden är nu cordoned (ingen ny scheduling)"
        fi

        # Step 2: Drain (for worker nodes)
        if [ "$is_worker" = true ] && [ "$skip_cordon_drain" != "true" ]; then
            echo -e "\n\033[34m📌 Steg 2: Drain noden\033[0m"
            echo "   Kör: kubectl drain $node --ignore-daemonsets --delete-emptydir-data --grace-period=60 --timeout=300s"

            if kubectl drain "$node" \
                --ignore-daemonsets \
                --delete-emptydir-data \
                --grace-period=60 \
                --timeout=300s 2>&1; then
                echo "✅ Noden är dränerad"
            else
                echo "❌ Drain misslyckades eller timeout"
                echo "   Försöker vänta lite och fortsätta..."
                sleep 5
            fi

            # Show pods being evicted
            echo "   Pods som evakuerats:"
            kubectl get pods --all-namespaces --field-selector spec.nodeName="$node" -o wide 2>/dev/null || true
        fi

        # Step 3: Upgrade Talos
        echo -e "\n\033[34m📌 Steg 3: Oppgraderar Talos\033[0m"
        echo "   Bild: factory.talos.dev/installer/$schematicID:$selectedVersion"

        if talosctl upgrade \
            --image "factory.talos.dev/installer/$schematicID:$selectedVersion" \
            --nodes "$node_ip" \
            --wait \
            --timeout 15m 2>&1; then
            echo "✅ Talos-uppgradering slutförd"
        else
            echo "❌ Talos-uppgradering misslyckades"
            echo "   Försöker uncordon om det är en worker..."
            if [ "$is_worker" = true ]; then
                kubectl uncordon "$node" 2>/dev/null || true
            fi
            continue
        fi

        # Step 4: Wait for node to come back and check health
        echo -e "\n\033[34m📌 Steg 4: Väntar på att noden ska bli redo\033[0m"
        echo "   Timeout: 10 minuter"

        if talosctl health \
            --nodes "$node_ip" \
            --wait-timeout 10m 2>&1; then
            echo "✅ Noden är vid god hälsa"
        else
            echo "⚠️  Health check timeout eller misslyckades"
            echo "   Kontrollerar status manuellt..."
        fi

        # Verify version
        echo "\n   Verifierar version..."
        talosctl version --nodes "$node_ip" --short 2>&1 | head -5

        # Check system services
        echo "\n   System services:"
        talosctl services --nodes "$node_ip" 2>&1 | grep -E "STATE|running" || true

        # Step 5: Verify Kubernetes node status
        echo -e "\n\033[34m📌 Steg 5: Verifierar Kubernetes-status\033[0m"
        local max_wait=120
        local waited=0
        while [ $waited -lt $max_wait ]; do
            local node_status
            node_status=$(kubectl get node "$node" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
            if [ "$node_status" = "True" ]; then
                echo "✅ Noden är Ready i Kubernetes"
                break
            fi
            echo "   Väntar på att noden ska bli Ready... ($waited/$max_wait s)"
            sleep 10
            waited=$((waited + 10))
        done

        if [ $waited -ge $max_wait ]; then
            echo "⚠️  Noden blev inte Ready inom $max_wait sekunder"
        fi

        kubectl get node "$node" --no-headers 2>/dev/null || true

        # Step 6: Uncordon (for worker nodes)
        if [ "$is_worker" = true ] && [ "$skip_cordon_drain" != "true" ]; then
            echo -e "\n\033[34m📌 Steg 6: Uncordon noden\033[0m"
            kubectl uncordon "$node"
            echo "✅ Noden är nu schedulable igen"
        fi

        # Step 7: Wait for stabilization before next node
        echo -e "\n\033[33m⏳ Väntar 2 minuter för kluster-stabilisering innan nästa nod...\033[0m"
        echo "   (Visar nya pods på $node:)"
        kubectl get pods --all-namespaces \
            --field-selector spec.nodeName="$node" \
            --watch 2>&1 &
        local watch_pid=$!
        sleep 120
        kill $watch_pid 2>/dev/null || true

        echo -e "\n\033[32m✅ Nod $node färdig!\033[0m"
    done

    echo -e "\n\033[32m════════════════════════════════════════════════════════════\033[0m"
    echo "\033[32m✅ ALLA NODER UPPGRADERADE!\033[0m"
    echo "\033[32m════════════════════════════════════════════════════════════\033[0m"

    # Post-upgrade verification
    echo -e "\n\033[34m📋 Post-uppgraderings-verifiering:\033[0m"
    echo "Alla noder:"
    kubectl get nodes

    echo "\nPods med problem:"
    kubectl get pods --all-namespaces 2>/dev/null | awk 'NR==1 || ($4!="Running" && $4!="Completed")' || true

    echo "\nPvcs med problem:"
    kubectl get pvc --all-namespaces 2>/dev/null | awk 'NR==1 || $2!="Bound"' || true
}

main_talos_update_config() (
    local config_dir
    config_dir=$(mktemp -d "${TMPDIR:-/tmp}/simon-talos-config.XXXXXX") || {
        echo "❌ Kunde inte skapa temporär katalog för Talos-konfigurationen" >&2
        return 1
    }
    trap 'rm -rf -- "$config_dir"' EXIT
    chmod 700 "$config_dir" || return 1
    _main_talos_update_config_impl "${1:-}" "$config_dir"
)

record_talos_node_failure() {
    printf '%s\n' "$2" >> "$1/failed-nodes"
}

_main_talos_update_config_impl() {
    local target_node_name="$1"
    local config_dir="$2"
    local infra_repo controlplane_ip YQ

    if ! YQ=$(resolve_yq); then
        echo "❌ Kunde inte hitta yq (mikefarah)"
        return 1
    fi
    SIMON_YQ="$YQ"

    if ! infra_repo=$(resolve_talos_infrastructure_repo); then
        echo "❌ Kunde inte hitta infrastructure-repo"
        return 1
    fi

    cd "$infra_repo/talos" || return 1
    echo "Använder infrastructure-repo: $infra_repo"

    # Talosconfig: den lokala används i första hand, 1Password är reserv.
    local talosconfig_file="$config_dir/talosconfig"
    if [ -f "$HOME/.talos/config" ]; then
        echo "Använder systemets talosconfig från ~/.talos/config"
        cp "$HOME/.talos/config" "$talosconfig_file" || return 1
    else
        echo "Hämtar talosconfig från 1Password..."
        umask 077
        mkdir -p "$HOME/.op" || return 1
        chmod 700 "$HOME/.op" || return 1
        if ! op signin --raw > "$HOME/.op/session"; then
            echo "❌ Kunde inte logga in med 1Password. Avbryter utan ändringar."
            return 1
        fi
        chmod 600 "$HOME/.op/session" || return 1
        if ! op read op://talos/talosconfig/talosconfig -o "$talosconfig_file" -f; then
            echo "❌ Kunde inte läsa Talos-konfigurationen från 1Password. Avbryter utan ändringar."
            return 1
        fi
    fi
    chmod 600 "$talosconfig_file" || return 1

    local TALOSCONFIG="$talosconfig_file"
    export TALOSCONFIG

    controlplane_ip=$("$YQ" '.nodes[] | select(.role == "controlplane") | .ip' nodes.yaml 2>/dev/null | head -1)

    echo "Kontrollerar talosconfig..."
    if ! talosctl version -n "$controlplane_ip" --short >/dev/null 2>&1; then
        echo "⚠️  Varning: Kan inte ansluta till kontrollplanet med nuvarande certifikat"
        echo "    Kontrollera att ~/.talos/config är uppdaterad"
    else
        echo "✅ Certifikatet fungerar"
    fi

    # Get list of node names to process
    local node_names
    if [ -z "$target_node_name" ]; then
        echo "Uppdaterar alla noder..."
        node_names=$("$YQ" '.nodes[].name' nodes.yaml)
    else
        if ! "$YQ" ".nodes[] | select(.name == \"$target_node_name\")" nodes.yaml | grep -q .; then
            echo "Ingen nod med namn $target_node_name hittades."
            return 1
        fi
        echo "Uppdaterar endast noden $target_node_name..."
        node_names="$target_node_name"
    fi

    echo "$node_names" | while IFS= read -r node_name; do
        # Get node data using the name
        node_name=$(echo "$node_name" | tr -d '"')
        local node_ip role
        node_ip=$("$YQ" ".nodes[] | select(.name == \"$node_name\") | .ip" nodes.yaml | tr -d '"')
        role=$("$YQ" ".nodes[] | select(.name == \"$node_name\") | .role" nodes.yaml | tr -d '"')
        local reference_ip="$controlplane_ip"

        echo "Bearbetar nod: $node_name med IP $node_ip"

        # Kontrollera om noden är nåbar
        if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
            echo "❌ Noden $node_name ($node_ip) är inte nåbar via nätverket."
            echo "   Hoppar över denna nod..."
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi
        echo "✅ Noden är nåbar via nätverket"

        # Kontrollera om noden svarar på talosctl-kommandon (TLS-certifikatkontroll)
        echo "Kontrollerar Talos-anslutning..."
        local node_in_maintenance=false

        if ! talosctl --talosconfig "$TALOSCONFIG" version -n "$node_ip" --short >/dev/null 2>&1; then
            # Anslutningen misslyckades. En nod i maintenance mode svarar med
            # ett eget (self-signed) certifikat, en initialiserad nod med
            # klustrets certifikat - men en fladdrig nod kan också ge
            # timeout. Testa därför alltid med --insecure innan något antas.
            echo "⚠️  Kan inte ansluta med klientcertifikat till $node_name ($node_ip)"
            echo "   Kontrollerar nodens status med --insecure..."

            local machine_status
            machine_status=$(talosctl --talosconfig "$TALOSCONFIG" get machinestatus --insecure -n "$node_ip" 2>&1)

            if echo "$machine_status" | grep -q "maintenance"; then
                node_in_maintenance=true
                echo "✅ Noden är i maintenance mode"
            elif echo "$machine_status" | grep -qE "running|ready"; then
                echo "❌ Noden är initialiserad men har fel klientcertifikat"
                echo "   För att installera om den, boota den till maintenance mode först:"
                echo "   1. Boota maskinen från nätverket (PXE)"
                echo "   2. Vänta tills den är i maintenance mode"
                echo "   3. Kör sedan: simon talos update config $node_name"
                echo "-----------------------------"
                record_talos_node_failure "$config_dir" "$node_name"
                continue
            else
                echo "❌ Noden svarar inte på Talos-API (--insecure): ${machine_status:0:120}"
                echo "   Noden är inte nåbar - hoppar över..."
                echo "-----------------------------"
                record_talos_node_failure "$config_dir" "$node_name"
                continue
            fi
        else
            echo "✅ Talos-anslutning fungerar"
            # Även om TLS fungerar, kolla om noden är i maintenance mode
            local machine_status
            machine_status=$(talosctl --talosconfig "$TALOSCONFIG" get machinestatus -n "$node_ip" 2>&1)
            if echo "$machine_status" | grep -q "maintenance"; then
                node_in_maintenance=true
                echo "✅ Noden är i maintenance mode"
            fi
        fi

        # Sätt node_initialized baserat på om noden är i maintenance mode eller inte
        local node_initialized
        if [ "$node_in_maintenance" = "true" ]; then
            node_initialized=false
        else
            node_initialized=true
        fi

        # Hämta talos-schematic-id för extensions
        local talos_schematic_id arch
        talos_schematic_id=$("$YQ" ".nodes[] | select(.name == \"$node_name\") | .\"talos-schematic-id\"" nodes.yaml 2>/dev/null | tr -d '"')
        arch=$("$YQ" ".nodes[] | select(.name == \"$node_name\") | .\"arch\"" nodes.yaml 2>/dev/null | tr -d '"')

        # Målversionen: repots deklarerade version, annars referensnodens.
        # Referensnodens version används bara som reserv - nodens egen version
        # kan vara äldre (det är ofta precis det vi vill rätta till).
        local target_version node_version ref_version
        target_version=$(talos_target_version "$infra_repo")
        ref_version=$(talos_server_version "$TALOSCONFIG" "$reference_ip")
        node_version=$(talos_server_version "$TALOSCONFIG" "$node_ip")

        if [ -z "$target_version" ]; then
            target_version="$ref_version"
        fi
        if [ -z "$target_version" ]; then
            target_version="$node_version"
        fi

        echo "  Målversion: ${target_version:-<okänd>} (noden kör: ${node_version:-<nåbar via maintenance>})"

        # Installer-image: schematic-instalören när vi vet vilken schematic
        # noden ska ha, annars den vanliga installer-imagen.
        local installer_image="ghcr.io/siderolabs/installer:${target_version:-vlatest}"
        if [ -n "$talos_schematic_id" ] && [ "$talos_schematic_id" != "null" ] && [ -n "$target_version" ]; then
            installer_image="factory.talos.dev/metal-installer/$talos_schematic_id:$target_version"
        fi

        # Nodens disk-patchar (Longhorn-volymer). Sätts före greningen så att
        # både den initialiserade och maintenance-vägen hittar dem.
        local role_dir="workers"
        [ "$role" = "controlplane" ] && role_dir="controlplanes"
        local disk_dir="patches/$role_dir/$node_name/disks"

        # Om noden är initierad, applicera konfiguration direkt
        if [ "$node_initialized" = "true" ]; then
            echo "Noden $node_ip är initialiserad, applicerar konfigurationen direkt."

            # Hämta nodens egen config (alla v1alpha1-dokument)
            echo "📝 Hämtar nodens nuvarande config..."
            local node_config_tmp="$config_dir/node_config_$node_name.yaml"
            local node_config_raw="$node_config_tmp.raw"
            if ! talosctl --talosconfig "$TALOSCONFIG" get machineconfig -o yaml -n "$node_ip" > "$node_config_raw" 2>/dev/null; then
                echo "  ⚠️ Kunde inte hämta nodens config, hoppar över..."
                echo "-----------------------------"
                record_talos_node_failure "$config_dir" "$node_name"
                continue
            fi
            if ! extract_machine_config_spec "$node_config_raw" "$node_config_tmp"; then
                rm -f "$node_config_raw" "$node_config_tmp"
                echo "  ⚠️ Nodens config innehöll ingen användbar spec, hoppar över..."
                echo "-----------------------------"
                record_talos_node_failure "$config_dir" "$node_name"
                continue
            fi
            rm "$node_config_raw"

            local node_hostname
            node_hostname=$("$YQ" eval-all 'select(.kind == "HostnameConfig") | .hostname' "$node_config_tmp" 2>/dev/null | head -1)

            echo "  ✅ Hämtad config för $node_name (hostname=${node_hostname:-<ej satt>})"

            # Applicera UserVolumeConfigs (normaliserade till v1.14)
            if [ -d "$disk_dir" ]; then
                local volume_count
                volume_count=$(find "$disk_dir" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null | wc -l | tr -d ' ')
                if [ "$volume_count" -gt 0 ]; then
                    echo "📝 Applicerar UserVolumeConfigs från $disk_dir..."

                    local failed=0
                    local volume_file volume_name
                    while IFS= read -r volume_file; do
                        volume_name=$("$YQ" eval-all 'select(.kind == "UserVolumeConfig") | .name // ""' "$volume_file" 2>/dev/null | head -1)
                        [ -z "$volume_name" ] && volume_name="$(basename "$volume_file")"

                        local normalized_volume="$config_dir/volume_$(basename "$volume_file")"
                        if ! talos_normalize_user_volume "$volume_file" "$normalized_volume"; then
                            echo "  ⚠️ $volume_name kunde inte normaliseras"
                            failed=$((failed + 1))
                            continue
                        fi

                        if talosctl --talosconfig "$TALOSCONFIG" patch machineconfig --nodes "$node_ip" \
                            --patch "@$normalized_volume" --mode no-reboot >/dev/null 2>&1; then
                            echo "  ✅ $volume_name applicerad"
                        else
                            echo "  ⚠️ $volume_name misslyckades"
                            failed=$((failed + 1))
                        fi
                    done < <(find "$disk_dir" -maxdepth 1 -name "*.yaml" -type f -print | sort)

                    if [ "$failed" -eq 0 ]; then
                        echo "  ✅ UserVolumeConfigs applicerade"
                    else
                        echo "  ⚠️ $failed UserVolumeConfig(s) misslyckades"
                        record_talos_node_failure "$config_dir" "$node_name"
                    fi
                fi
            fi

            # Uppdatera hostname om det inte matchar. HostnameConfig är ett
            # eget dokument i v1alpha1 - machine.network.hostname är borta.
            if [ "$node_hostname" != "$node_name" ]; then
                echo "📝 Uppdaterar hostname: $node_name..."
                local hostname_doc="$config_dir/hostname_patch_$node_name.yaml"
                talos_hostname_doc "$node_name" > "$hostname_doc"
                if talosctl --talosconfig "$TALOSCONFIG" patch machineconfig --nodes "$node_ip" \
                    --patch "@$hostname_doc" --mode no-reboot >/dev/null 2>&1; then
                    echo "  ✅ Hostname uppdaterad"
                else
                    echo "  ❌ Hostname kunde inte uppdateras"
                    record_talos_node_failure "$config_dir" "$node_name"
                fi
            fi

            # Installationsdisk + installer image. I v1alpha1 ligger det i
            # UnattendedInstallConfig - machine.install avvisas av Talos.
            local node_patch_file
            if node_patch_file=$(talos_node_patch_file "$role" "$node_name" "patches"); then
                local install_match
                if install_match=$(talos_install_match "$node_patch_file"); then
                    local install_doc="$config_dir/install_patch_$node_name.yaml"
                    talos_install_doc "$install_match" "$installer_image" > "$install_doc"
                    if talosctl --talosconfig "$TALOSCONFIG" patch machineconfig --nodes "$node_ip" \
                        --patch "@$install_doc" --mode no-reboot >/dev/null 2>&1; then
                        echo "  ✅ Installationsdisk och installer-image applicerade"
                    else
                        echo "  ❌ UnattendedInstallConfig kunde inte appliceras"
                        record_talos_node_failure "$config_dir" "$node_name"
                    fi
                else
                    echo "  ❌ Kunde inte tolka installationsdisken i $node_patch_file"
                    record_talos_node_failure "$config_dir" "$node_name"
                fi
            else
                echo "  ⚠️  Ingen patchfil hittad för $node_name (patches/${role}s/$node_name/patch.yaml)"
            fi

            # System extensions: schematicen i nodes.yaml ska vara installerad.
            local installed_schematic
            installed_schematic=$(talosctl --talosconfig "$TALOSCONFIG" get extensions -n "$node_ip" 2>/dev/null \
                | awk '$6 == "schematic" {print $7; exit}')

            if [ -n "$talos_schematic_id" ] && [ "$talos_schematic_id" != "null" ]; then
                local needs_upgrade=false
                local upgrade_reason=""

                if [ "$installed_schematic" != "$talos_schematic_id" ]; then
                    needs_upgrade=true
                    upgrade_reason="schematicen är $installed_schematic, ska vara $talos_schematic_id"
                elif [ -n "$node_version" ] && [ -n "$target_version" ] && [ "$node_version" != "$target_version" ]; then
                    needs_upgrade=true
                    upgrade_reason="noden kör $node_version, målet är $target_version"
                fi

                if [ "$needs_upgrade" = "true" ]; then
                    echo "📝 Uppdaterar noden (upgrade)..."
                    echo "  Orsak: $upgrade_reason"
                    echo "  Installerar med schematic: $talos_schematic_id"
                    echo "  Talos version: ${target_version:-vlatest}"

                    local upgrade_image="factory.talos.dev/metal-installer/$talos_schematic_id:${target_version:-vlatest}"
                    local upgrade_output upgrade_rc=0
                    upgrade_output=$(talosctl --talosconfig "$TALOSCONFIG" upgrade \
                        --image "$upgrade_image" -n "$node_ip" --wait --timeout 10m 2>&1) || upgrade_rc=$?

                    echo "$upgrade_output" | sed 's/^/    /'

                    if [ $upgrade_rc -ne 0 ] && ! echo "$upgrade_output" | grep -qi "no upgrade\|already"; then
                        echo "  ⚠️ Upgrade misslyckades"
                        record_talos_node_failure "$config_dir" "$node_name"
                    else
                        echo "  ✅ System extensions installerade"
                    fi
                else
                    echo "  ✅ System extensions matchar nodes.yaml"
                fi
            fi

            echo "-----------------------------"
            continue
        fi

        # För noder i maintenance mode, generera konfiguration
        echo "📝 Installerar noden $node_name i maintenance mode..."

        # Hämta referens-nod baserat på roll
        reference_ip="$controlplane_ip"
        local reference_role="controlplane"

        if [ "$role" = "worker" ]; then
            # Hitta en fungerande worker att använda som referens
            local worker_ip
            worker_ip=$("$YQ" ".nodes[] | select(.role == \"worker\") | select(.name != \"$node_name\") | select(.initialized == true) | .ip" nodes.yaml 2>/dev/null | head -1)
            if [ -n "$worker_ip" ] && [ "$worker_ip" != "null" ]; then
                reference_ip="$worker_ip"
                reference_role="worker"
                echo "📝 Hittade worker $reference_ip som referens för worker-nod"
            else
                echo "⚠️  Ingen fungerande worker hittad, använder controlplane som referens"
            fi
        fi

        echo "📝 Hämtar konfiguration från referens-nod $reference_ip (role: $reference_role)..."

        # Spara machineconfig från referens-noden tillfälligt
        local reference_config="$config_dir/reference_config.yaml"
        if ! talosctl --talosconfig "$TALOSCONFIG" get machineconfig -o yaml -n "$reference_ip" 2>/dev/null > "$reference_config.raw"; then
            echo "❌ Kunde inte hämta konfiguration från $reference_ip"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        # Extrahera spec-fältet (alla v1alpha1-dokument)
        if ! extract_machine_config_spec "$reference_config.raw" "$reference_config"; then
            rm -f "$reference_config.raw" "$reference_config"
            echo "❌ Referensnodens konfiguration saknade en användbar spec"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi
        rm "$reference_config.raw"

        # Nodens egen patch måste finnas - annars installerar vi med
        # referensnodens diskSelector.
        local node_patch_file
        if ! node_patch_file=$(talos_node_patch_file "$role" "$node_name" "patches"); then
            echo "❌ Saknar nodspecifik patch: patches/${role}s/$node_name/patch.yaml"
            echo "   Avbryter för att inte installera med referensnodens diskSelector."
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        local install_match
        if ! install_match=$(talos_install_match "$node_patch_file"); then
            echo "❌ Kunde inte tolka installationsdisken i $node_patch_file"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        # Bygg nodens config från referensens ALLA dokument + nodens egna delar.
        local config_file="$config_dir/machine_config_$node_name.yaml"
        if ! talos_build_node_config "$reference_config" "$role" "$node_name" \
            "$install_match" "$installer_image" "$reference_role" "$config_file"; then
            echo "❌ Kunde inte bygga configen för $node_name"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        echo "Config förberedd för noden $node_ip"

        if [ ! -f "$config_file" ]; then
            echo "FEL: Konfigurationsfilen $config_file skapades INTE!"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        echo "📝 Applicerar konfiguration på $node_name..."

        # MachineConfig måste appliceras först i maintenance mode. Därefter
        # kräver Talos klientcertifikat, så UserVolumeConfigs appliceras med
        # den riktiga talosconfig-filen och inte med --insecure.
        if ! talosctl apply-config --insecure --nodes "$node_ip" --mode=auto --file "$config_file" 2>&1; then
            echo "❌ MachineConfig misslyckades"
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi
        echo "  ✅ MachineConfig applicerad"

        # Applicera endast nodens egna UserVolumeConfigs. Referensnodens
        # UserVolumeConfigs har medvetet aldrig kopierats till config_file.
        local volume_files=()
        if [ -d "$disk_dir" ]; then
            shopt -s nullglob
            volume_files=("$disk_dir"/*.yaml)
            shopt -u nullglob
        fi

        local failed_volume_configs=0
        local volume_file volume_name volume_kind
        if [ "${#volume_files[@]}" -gt 0 ]; then
            echo "  📝 Applicerar ${#volume_files[@]} UserVolumeConfig(s) från $disk_dir..."
            for volume_file in "${volume_files[@]}"; do
                volume_kind=$("$YQ" eval-all 'select(.kind == "UserVolumeConfig") | .kind' "$volume_file" 2>/dev/null | head -1)
                volume_name=$("$YQ" eval-all 'select(.kind == "UserVolumeConfig") | .name // ""' "$volume_file" 2>/dev/null | head -1)
                [ -z "$volume_name" ] && volume_name="$(basename "$volume_file")"

                if [ "$volume_kind" != "UserVolumeConfig" ]; then
                    echo "  ❌ Ogiltig UserVolumeConfig-fil: $volume_file"
                    failed_volume_configs=$((failed_volume_configs + 1))
                    continue
                fi

                local normalized_volume="$config_dir/volume_$(basename "$volume_file")"
                if ! talos_normalize_user_volume "$volume_file" "$normalized_volume"; then
                    echo "  ❌ $volume_name kunde inte normaliseras"
                    failed_volume_configs=$((failed_volume_configs + 1))
                    continue
                fi

                echo "  📝 Applicerar UserVolumeConfig: $volume_name..."
                local volume_applied=false
                local attempt
                for attempt in 1 2 3; do
                    if talosctl --talosconfig "$TALOSCONFIG" patch machineconfig --nodes "$node_ip" \
                        --patch "@$normalized_volume" --mode no-reboot >/dev/null 2>&1; then
                        volume_applied=true
                        break
                    fi
                    if [ "$attempt" -lt 3 ]; then
                        echo "  ℹ️ API:t är inte redo, försöker igen ($((attempt + 1))/3)..."
                        sleep 2
                    fi
                done

                if [ "$volume_applied" = true ]; then
                    echo "  ✅ $volume_name applicerad"
                else
                    echo "  ❌ $volume_name misslyckades efter 3 försök"
                    failed_volume_configs=$((failed_volume_configs + 1))
                fi
            done
        fi

        if [ "$failed_volume_configs" -gt 0 ]; then
            echo "❌ MachineConfig applicerad, men $failed_volume_configs UserVolumeConfig(s) misslyckades."
            echo "   Noden markeras inte som färdig. Kontrollera certifikat/API och kör om efter åtgärd."
            echo "-----------------------------"
            record_talos_node_failure "$config_dir" "$node_name"
            continue
        fi

        echo "✅ MachineConfig och alla nodspecifika UserVolumeConfigs applicerade"

        echo "ℹ️  Noden startas om och hostname kommer att sättas."
        "$YQ" -i "(.nodes[] | select(.name == \"$node_name\").initialized) = true" nodes.yaml 2>/dev/null || true

        echo "-----------------------------"
    done

    if [ -f "$config_dir/failed-nodes" ]; then
        echo "❌ Konfigurationen misslyckades för följande noder:"
        sort -u "$config_dir/failed-nodes" | sed 's/^/  - /'
        return 1
    fi

    local message
    if [ -z "$target_node_name" ]; then
        message="Konfiguration har applicerats på alla noder."
    else
        message="Konfiguration har applicerats på noden $target_node_name."
    fi
    echo "$message"
}

main_talos_update_kubeconfig() {
    controlplanes=$(yq '.nodes[] | select(.role == "controlplane") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    talosctl kubeconfig /home/simon/repos/infrastructure/talos/kubeconfig
}

main_talos_systemdisks() {
    all_nodes=$(yq '.nodes[] | select(.initialized == true)' /home/simon/repos/infrastructure/talos/nodes.yaml)
    
    for node in $(yq '.nodes[] | select(.initialized == true) | .name' /home/simon/repos/infrastructure/talos/nodes.yaml); do
        node=$(echo "$node" | tr -d '"')
        node_ip=$(yq ".nodes[] | select(.name == \"$node\") | .ip" /home/simon/repos/infrastructure/talos/nodes.yaml | tr -d '"')
        
        if timeout 2 talosctl -n "$node_ip" version >/dev/null 2>&1; then
            echo -e "\033[34m=== $node ===\033[0m"
            talosctl get systemdisks -n "$node_ip"
            echo ""
        else
            echo "⚠️  Nod $node ($node_ip) är inte tillgänglig, hoppar över..."
        fi
    done
}

main_talos_reboot_all() {
    controlplanes=$(yq '.nodes[] | select(.role == "controlplane") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    workers=$(yq '.nodes[] | select(.role == "worker") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    nodes="${controlplanes}${workers}"
    talosctl reboot -n "$nodes"
}
