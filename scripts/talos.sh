#!/bin/bash

# Converted from talos.nu

export TALOSCONFIG=/home/simon/.talos/config

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

extract_machine_config_spec() {
    local raw_config_file="$1"
    local extracted_config_file="$2"

    [ -f "$raw_config_file" ] || return 1

    awk '
        /^[[:space:]]*spec: \|$/ { in_spec=1; next }
        in_spec {
            if ($0 !~ /^[[:space:]]/ && $0 !~ /^[[:space:]]*$/) exit
            if (!indent_set && $0 ~ /[^[:space:]]/) {
                match($0, /^[[:space:]]*/)
                indent=RLENGTH
                indent_set=1
            }
            if (indent_set && length($0) >= indent) print substr($0, indent + 1)
            else print
        }
    ' "$raw_config_file" > "$extracted_config_file"

    [ -s "$extracted_config_file" ]
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
        nodes=$(kubectl get nodes --kubeconfig "/tmp/kubeconfig-certificate" | awk 'NR>1 {print $1}')
    else
        nodes=$(kubectl get nodes | awk 'NR>1 {print $1}')
    fi

    if [ -z "$target_node" ]; then
        echo -e "\033[34mVilka noder vill du uppdatera?\033[0m"
        selectedNodes=$(fzfSelect "$nodes")
    else
        if echo "$nodes" | grep -qw "$target_node"; then
            selectedNodes="$target_node"
        else
            echo "❌ Noden $target_node hittades inte bland klustrets noder"
            return 1
        fi
    fi
    selectedNodesString=$(echo "$selectedNodes" | tr ' ' ',')
    schematicID=$(yq ".nodes[] | select(.name == \"$selectedNodesString\") | .\"talos-schematic-id\"" /home/simon/repos/infrastructure/talos/nodes.yaml | head -1 | tr -d '"')
    arch=$(yq ".nodes[] | select(.name == \"$selectedNodesString\") | .\"arch\"" /home/simon/repos/infrastructure/talos/nodes.yaml | head -1 | tr -d '"')

    if [ -z "$schematicID" ]; then
        echo "❌ Fel: Kunde inte hämta talos-schematic-id för nod $selectedNodesString"
        echo "   Kontrollera att noden finns i nodes.yaml"
        return 1
    fi

    echo "🔧 Uppgraderar nod $selectedNodesString med schematic: $schematicID"
    echo "🔗 https://factory.talos.dev/image/$schematicID/$selectedVersion/metal-$arch.raw.xz"
    talosctl upgrade --image "factory.talos.dev/installer/$schematicID:$selectedVersion" -n "$selectedNodesString"
}

main_talos_update_config() {
    local target_node_name="$1"
    local infra_repo

    if ! infra_repo=$(resolve_talos_infrastructure_repo); then
        echo "❌ Kunde inte hitta infrastructure-repo"
        return 1
    fi

    cd "$infra_repo/talos" || return 1
    echo "Använder infrastructure-repo: $infra_repo"

    mkdir -p ~/.op
    chmod 700 ~/.op
    if ! op signin --raw > ~/.op/session; then
        echo "❌ Kunde inte logga in med 1Password. Avbryter utan ändringar."
        return 1
    fi
    if ! op read op://talos/secrets/secrets.yaml -o secrets.yaml -f || \
        ! op read op://talos/talosconfig/talosconfig -o talosconfig -f; then
        echo "❌ Kunde inte läsa Talos-konfigurationen från 1Password. Avbryter utan ändringar."
        return 1
    fi
    chmod 600 secrets.yaml talosconfig

    local config_dir
    config_dir=$(mktemp -d "${TMPDIR:-/tmp}/simon-talos-config.XXXXXX") || {
        echo "❌ Kunde inte skapa temporär katalog för Talos-konfigurationen"
        return 1
    }
    controlplane_ip=$(yq '.nodes[] | select(.role == "controlplane") | .ip' nodes.yaml | head -1 | tr -d '"')

    # Använd systemets talosconfig om den finns och fungerar
    echo "Kontrollerar talosconfig..."
    if [ -f "$HOME/.talos/config" ]; then
        echo "Använder systemets talosconfig från ~/.talos/config"
        cp "$HOME/.talos/config" ./talosconfig
        chmod 600 talosconfig
    fi
    
    export TALOSCONFIG=./talosconfig
    
    # Kontrollera om certifikatet fungerar
    if ! talosctl version -n "$controlplane_ip" --short >/dev/null 2>&1; then
        echo "⚠️  Varning: Kan inte ansluta till kontrollplanet med nuvarande certifikat"
        echo "    Kontrollera att ~/.talos/config är uppdaterad"
    else
        echo "✅ Certifikatet fungerar"
    fi

    # # Get Talos version from controlplane
    # echo "Hämtar Talos-version från klustret..."
    # talos_version=$(talosctl version -n "$controlplane_ip" --short 2>/dev/null | grep "Tag:" | awk '{print $2}' | sed 's/^v//' || echo "")
    # if [ -n "$talos_version" ]; then
    #     echo "Hittade Talos version: v$talos_version"
    #     talos_version_flag="--talos-version v$talos_version"
    # else
    #     echo "Kunde inte hämta Talos-version, använder senaste"
    #     talos_version_flag=""
    # fi
    #
    # # Hämta Kubernetes-version från det befintliga klustret
    # if kubectl get nodes >/dev/null 2>&1; then
    #     current_k8s_version=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')
    #     k8s_version="v$current_k8s_version"
    #     echo "Hämtar Kubernetes-version från klustret: $k8s_version"
    # else
    #     echo "Kan inte nå klustret, vilken Kubernetes-version vill du använda?"
    #     echo "Exempel: v1.30.0, v1.31.0, v1.32.0"
    #     read -r k8s_version
    # fi
    #
    # # Lägg till 'v' om det inte finns
    # if [[ ! "$k8s_version" =~ ^v ]]; then
    #     k8s_version="v$k8s_version"
    # fi
    #
    # k8s_version_flag="--kubernetes-version $k8s_version"

    # Get list of node names to process
    if [ -z "$target_node_name" ]; then
        echo "Uppdaterar alla noder..."
        node_names=$(yq '.nodes[].name' nodes.yaml)
    else
        if ! yq ".nodes[] | select(.name == \"$target_node_name\")" nodes.yaml | grep -q .; then
            echo "Ingen nod med namn $target_node_name hittades."
            return 1
        fi
        echo "Uppdaterar endast noden $target_node_name..."
        node_names="$target_node_name"
    fi

    echo "$node_names" | while IFS= read -r node_name; do
        # Get node data using the name
        node_name=$(echo "$node_name" | tr -d '"')
        node_ip=$(yq ".nodes[] | select(.name == \"$node_name\") | .ip" nodes.yaml | tr -d '"')
        role=$(yq ".nodes[] | select(.name == \"$node_name\") | .role" nodes.yaml | tr -d '"')
        local reference_ip="$controlplane_ip"
        
        echo "Bearbetar nod: $node_name med IP $node_ip"

        # Kontrollera om noden är nåbar
        if ! ping -c 1 -W 2 "$node_ip" >/dev/null 2>&1; then
            echo "❌ Noden $node_name ($node_ip) är inte nåbar via nätverket."
            echo "   Kontrollera att:"
            echo "   - Datorn är påslagen"
            echo "   - Nätverkskabeln är ansluten"
            echo "   - IP-adressen är korrekt (förväntat: $node_ip)"
            echo "   Hoppar över denna nod..."
            echo "-----------------------------"
            continue
        fi
        echo "✅ Noden är nåbar via nätverket"

        # Kontrollera om noden svarar på talosctl-kommandon (TLS-certifikatkontroll)
        echo "Kontrollerar Talos-anslutning..."
        node_in_maintenance=false

        if ! talosctl --talosconfig talosconfig version -n "$node_ip" --short >/dev/null 2>&1; then
            tls_error=$(talosctl --talosconfig talosconfig version -n "$node_ip" --short 2>&1 | grep -i "certificate\|tls\|auth" || echo "")
            if [ -n "$tls_error" ]; then
                echo "⚠️  TLS-fel vid anslutning till $node_name ($node_ip)"
                echo "   Försöker med --insecure för att kontrollera om noden är i maintenance mode..."

                # Försök med --insecure för att kontrollera nodens verkliga status
                machine_status=$(talosctl --talosconfig talosconfig get machinestatus --insecure -n "$node_ip" 2>&1)

                if echo "$machine_status" | grep -q "maintenance"; then
                    node_in_maintenance=true
                    echo "✅ Noden är i maintenance mode"
                elif echo "$machine_status" | grep -q "running"; then
                    echo "❌ Noden är initialiserad men har fel klientcertifikat"
                    echo "   För att installera om den, boota den till maintenance mode först:"
                    echo "   1. Boota maskinen från nätverket (PXE)"
                    echo "   2. Vänta tills den är i maintenance mode"
                    echo "   3. Kör sedan: simon talos update config $node_name"
                    echo "-----------------------------"
                    continue
                else
                    echo "⚠️  Kan inte avgöra nodens status via --insecure"
                    echo "   Fortsätter med försiktighet..."
                fi
            else
                echo "⚠️  Kan inte ansluta till $node_name, noden kan vara nere"
            fi
        else
            echo "✅ Talos-anslutning fungerar"
            # Även om TLS fungerar, kolla om noden är i maintenance mode
            machine_status=$(talosctl --talosconfig talosconfig get machinestatus -n "$node_ip" 2>&1)
            if echo "$machine_status" | grep -q "maintenance"; then
                node_in_maintenance=true
                node_initialized=false
                echo "✅ Noden är i maintenance mode"
            fi
        fi

        # Sätt node_initialized baserat på om noden är i maintenance mode eller inte
        if [ "$node_in_maintenance" = "true" ]; then
            node_initialized=false
        else
            node_initialized=true
        fi

        # Hämta talos-schematic-id för extensions
        local talos_schematic_id arch
        talos_schematic_id=$(yq ".nodes[] | select(.name == \"$node_name\") | .\"talos-schematic-id\"" nodes.yaml 2>/dev/null | tr -d '"')
        arch=$(yq ".nodes[] | select(.name == \"$node_name\") | .\"arch\"" nodes.yaml 2>/dev/null | tr -d '"')
        
        # Applicera extensions via upgrade om talos-schematic-id finns
        local node_needs_extension_upgrade=false
        if [ -n "$talos_schematic_id" ] && [ "$talos_schematic_id" != "null" ]; then
            # Kontrollera om extensions redan är installerade
            local current_extensions
            current_extensions=$(talosctl --talosconfig talosconfig get extensions -n "$node_ip" -o json 2>/dev/null | jq -r 'length' || echo "0")
            if [ "$current_extensions" = "0" ] || [ -z "$current_extensions" ]; then
                node_needs_extension_upgrade=true
            fi
        fi

        # Om noden är initierad, applicera konfiguration direkt
        if [ "$node_initialized" = "true" ]; then
            echo "Noden $node_ip är initialiserad, applicerar konfigurationen direkt."

            # Hämta nodens egen config och visa viktiga fält
            echo "📝 Hämtar nodens nuvarande config..."
            local node_config_tmp="$config_dir/node_config_$node_name.yaml"
            local node_config_raw="$node_config_tmp.raw"
            if ! talosctl --talosconfig talosconfig get machineconfig -o yaml -n "$node_ip" > "$node_config_raw" 2>/dev/null; then
                echo "  ⚠️ Kunde inte hämta nodens config, hoppar över..."
                echo "-----------------------------"
                continue
            fi
            if ! extract_machine_config_spec "$node_config_raw" "$node_config_tmp"; then
                rm -f "$node_config_raw" "$node_config_tmp"
                echo "  ⚠️ Nodens config innehöll ingen användbar spec, hoppar över..."
                echo "-----------------------------"
                continue
            fi
            rm "$node_config_raw"

            # Verifiera kritiska fält i nodens egen config
            local node_vip node_hostname node_install_image
            node_vip=$(yq -r 'select(.machine != null) | .machine.network.interfaces[0].vip // empty' "$node_config_tmp" 2>/dev/null | head -1)
            node_hostname=$(yq -r 'select(.machine != null) | .machine.network.hostname // empty' "$node_config_tmp" 2>/dev/null | head -1)
            node_install_image=$(yq -r 'select(.machine != null) | .machine.install.image // empty' "$node_config_tmp" 2>/dev/null | head -1)

            echo "  ✅ Hämtad config för $node_name (hostname=$node_hostname, vip=${node_vip:-<ej satt>}, install=${node_install_image:-<default>})"

            # Hämta klustrets version för att uppdatera installer image
            local cluster_version
            cluster_version=$(talosctl --talosconfig talosconfig version -n "$reference_ip" 2>/dev/null | grep "Tag:" | head -1 | awk '{print $2}' || echo "")
            if [ -z "$cluster_version" ]; then
                echo "  ⚠️ Kunde inte hämta klustrets version, använder <default>"
                cluster_version=""
            else
                echo "  ✅ Klustret kör Talos $cluster_version"
            fi

            # Kontrollera om installer image behöver uppdateras
            local needs_install_update=false
            if [ -n "$cluster_version" ] && [ -n "$node_install_image" ]; then
                # Extrahera versionen ur install.image (t.ex. ghcr.io/siderolabs/installer:v1.14.0)
                local node_installer_version
                node_installer_version=$(echo "$node_install_image" | grep -oP 'v\d+\.\d+\.\d+' | head -1)
                if [ "$node_installer_version" != "$cluster_version" ]; then
                    echo "  ⚠️ Installer version $node_installer_version != klustret $cluster_version"
                    needs_install_update=true
                fi
            fi

            # Applicera UserVolumeConfigs separat (Talos stödjer inte multi-doc patch)
            # Kolla i nodens egna struktur: patches/workers/<nod>/disks/*.yaml
            local disk_dir="patches/workers/$node_name/disks"
            if [ -d "$disk_dir" ]; then
                local volume_count
                volume_count=$(find "$disk_dir" -maxdepth 1 -name "*.yaml" -type f 2>/dev/null | wc -l | tr -d ' ')
                if [ "$volume_count" -gt 0 ]; then
                    echo "📝 Applicerar UserVolumeConfigs från $disk_dir..."

                    local failed=0
                    local volume_file volume_name
                    while IFS= read -r volume_file; do
                        volume_name=$(yq -r '.name // "<namnlös>"' "$volume_file" 2>/dev/null)

                        if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                            --patch "@$volume_file" --mode no-reboot 2>/dev/null; then
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
                    fi
                fi
            fi

            # Uppdatera hostname om det inte matchar. YAML-patch används i
            # stället för JSON6902 eftersom nodens config kan vara multi-doc.
            if [ "$node_hostname" != "$node_name" ]; then
                echo "📝 Uppdaterar hostname: $node_name..."
                local hostname_patch="$config_dir/hostname_patch_$node_name.yaml"
                cat > "$hostname_patch" <<EOF
machine:
  network:
    hostname: "$node_name"
EOF
                if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                    --patch "@$hostname_patch" --mode no-reboot 2>&1; then
                    echo "  ✅ Hostname uppdaterad"
                else
                    echo "  ❌ Hostname kunde inte uppdateras"
                fi
            fi

            # Applicera diskSelector från nodens patch. YAML-patch undviker
            # JSON6902-felet på multi-document machineconfig.
            local disk_serial=""
            local node_patch="patches/workers/$node_name/patch.yaml"
            if [ -f "$node_patch" ]; then
                disk_serial=$(yq -r '.machine.install.diskSelector.serial // empty' "$node_patch" 2>/dev/null)
            fi
            if [ -n "$disk_serial" ]; then
                echo "📝 Lägger till diskSelector (serial: $disk_serial)..."
                local disk_patch="$config_dir/disk_patch_$node_name.yaml"
                cat > "$disk_patch" <<EOF
machine:
  install:
    diskSelector:
      serial: "$disk_serial"
EOF
                if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                    --patch "@$disk_patch" --mode no-reboot 2>&1; then
                    echo "  ✅ diskSelector applicerad"
                else
                    echo "  ❌ diskSelector kunde inte appliceras"
                fi
            fi

            # Uppdatera installer image om det behövs
            if [ "$needs_install_update" = true ]; then
                echo "📝 Uppdaterar installer image till $cluster_version..."
                if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                    --patch "[{\"op\": \"replace\", \"path\": \"/machine/install/image\", \"value\": \"ghcr.io/siderolabs/installer:$cluster_version\"}]" \
                    --mode auto 2>&1 | grep -v "skipped"; then
                    echo "  ✅ Installer image uppdaterad (nod $node_name kommer att reboota)"
                else
                    echo "  ⚠️ Installer image uppdatering misslyckades"
                fi
            fi

            # Installera extensions om de inte redan finns
            if [ "$node_needs_extension_upgrade" = true ] && [ -n "$talos_schematic_id" ] && [ "$talos_schematic_id" != "null" ]; then
                echo "📝 Installerar extensions via upgrade..."
                echo "  Installerar med schematic: $talos_schematic_id"
                echo "🔗 https://factory.talos.dev/image/${talos_schematic_id}/${cluster_version}/metal-${arch}.raw.xz"

                if [ -z "$cluster_version" ]; then
                    cluster_version="vlatest"
                fi

                echo "  Talos version: $cluster_version"

                if talosctl upgrade --image "factory.talos.dev/installer/$talos_schematic_id:$cluster_version" -n "$node_ip" --wait --timeout 10m 2>&1; then
                    echo "  ✅ Extensions installerade (Talos upgrade med schematic $talos_schematic_id)"
                else
                    echo "  ⚠️ Upgrade misslyckades med version $cluster_version"
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
            local worker_ip=$(yq ".nodes[] | select(.role == \"worker\") | select(.name != \"$node_name\") | select(.initialized == true) | .ip" nodes.yaml 2>/dev/null | head -1 | tr -d '"')
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
        talosctl --talosconfig talosconfig get machineconfig -o yaml -n "$reference_ip" 2>/dev/null > "$reference_config.raw" || {
            echo "❌ Kunde inte hämta konfiguration från $reference_ip"
            echo "-----------------------------"
            continue
        }
        
        # Extrahera spec-fältet och normalisera YAML-indenteringen.
        if ! extract_machine_config_spec "$reference_config.raw" "$reference_config"; then
            rm -f "$reference_config.raw" "$reference_config"
            echo "❌ Referensnodens konfiguration saknade en användbar spec"
            echo "-----------------------------"
            continue
        fi
        rm "$reference_config.raw"

        local node_patch="patches/${role}s/$node_name/patch.yaml"
        if [ ! -f "$node_patch" ]; then
            echo "❌ Saknar nodspecifik patch: $node_patch"
            echo "   Avbryter för att inte installera med referensnodens diskSelector."
            echo "-----------------------------"
            continue
        fi

        # Använd endast MachineConfig-dokumentet från referensen och lägg på
        # nodens egna patch. UserVolumeConfigs appliceras separat nedan.
        local config_file="$config_dir/machine_config_$node_name.yaml"
        awk '/^---$/{exit} {print}' "$reference_config" > "$config_file"
        yq -y --slurp '.[0] * .[1]' \
            "$config_file" "$node_patch" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file" || {
            echo "❌ Kunde inte lägga nodpatchen $node_patch på MachineConfig"
            echo "-----------------------------"
            continue
        }

        # Hämta klustrets Talos-version för att sätta rätt installer image
        local cluster_version
        cluster_version=$(talosctl --talosconfig talosconfig version -n "$reference_ip" 2>/dev/null | grep "Tag:" | head -1 | awk '{print $2}' || echo "")
        if [ -z "$cluster_version" ]; then
            echo "  ⚠️ Kunde inte hämta klustrets version, behåller referens-configens installer"
        else
            echo "  ✅ Klustret kör Talos $cluster_version"
        fi

        # Ta bort fält som är SPECIFIKA för referens-noden och inte ska kopieras
        # VIKTIGT: Varje nod behöver sin egen VIP och sin egen machine.token
        if command -v yq &> /dev/null; then
            # Ta bort cluster.discovery (kräver discovery service secret som inte finns)
            yq -y 'del(.cluster.discovery) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
            # Ta bort refreshInterval
            yq -y 'del(.cluster.refreshInterval) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
            # Ta bort VIP — varje nod har sin egen VIP (load balancer), inte referens-nodens
            # VIP:n sätts automatiskt av Talos baserat på /network/interfaces om den inte finns här
            yq -y 'del(.machine.network.interfaces[0].vip) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
            echo "  ✅ Tog bort referens-nodens VIP från config (varje nod behöver sin egen)"
            # Ta bort machine.token — varje node har sin egen unika token för Kubelet-auth
            yq -y 'del(.machine.token) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
            echo "  ✅ Tog bort referens-nodens machine.token (varje nod har egen token)"
            
            # Om vi installerar en worker men referensen var en controlplane, ta bort controlplane-specifika fält
            if [ "$role" = "worker" ] && [ "$reference_role" = "controlplane" ]; then
                echo "  ℹ️  Konverterar controlplane-config till worker-config..."
                # Ta bort controlplane-specifika fält
                yq -y 'del(.cluster.apiServerArgs) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                yq -y 'del(.cluster.controllerManagerArgs) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                yq -y 'del(.cluster.schedulerArgs) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                yq -y 'del(.cluster.etcdArgs) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                yq -y 'del(.cluster.localApiServerEndpoint) 2>/dev/null' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                echo "  ✅ Tog bort controlplane-specifika fält (apiServerArgs, controllerManagerArgs, schedulerArgs, etcdArgs)"
            fi
            # Uppdatera installer image till klustrets version
            if [ -n "$cluster_version" ]; then
                yq -y '.machine.install.image = "ghcr.io/siderolabs/installer:'"$cluster_version"'"' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
                echo "  ✅ Uppdaterade installer image till $cluster_version"
            fi
            # Sätt hostname
            yq -y '.machine.network.hostname = "'$node_name'"' "$config_file" > "$config_file.tmp" 2>/dev/null && mv "$config_file.tmp" "$config_file" || true
            echo "  ✅ Sätter hostname till $node_name"
        fi

        echo "Config förberedd för noden $node_ip"

        if [ ! -f "$config_file" ]; then
            echo "FEL: Konfigurationsfilen $config_file skapades INTE!"
            echo "-----------------------------"
            continue
        fi

        echo "📝 Applicerar konfiguration på $node_name..."

        # MachineConfig måste appliceras först i maintenance mode. Därefter
        # kräver Talos klientcertifikat, så UserVolumeConfigs appliceras med
        # den riktiga talosconfig-filen och inte med --insecure.
        if ! talosctl apply-config --insecure --nodes "$node_ip" --mode=auto --file "$config_file" 2>&1; then
            echo "❌ MachineConfig misslyckades"
            echo "-----------------------------"
            continue
        fi
        echo "  ✅ MachineConfig applicerad"

        # Applicera endast nodens egna UserVolumeConfigs. Referensnodens
        # UserVolumeConfigs har medvetet aldrig kopierats till config_file.
        local disk_dir="patches/${role}s/$node_name/disks"
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
                volume_kind=$(yq -r '.kind // empty' "$volume_file" 2>/dev/null)
                volume_name=$(yq -r '.name // "<namnlös>"' "$volume_file" 2>/dev/null)

                if [ "$volume_kind" != "UserVolumeConfig" ] || [ "$volume_name" = "<namnlös>" ]; then
                    echo "  ❌ Ogiltig UserVolumeConfig-fil: $volume_file"
                    failed_volume_configs=$((failed_volume_configs + 1))
                    continue
                fi

                echo "  📝 Applicerar UserVolumeConfig: $volume_name..."
                local volume_applied=false
                local attempt
                for attempt in 1 2 3; do
                    if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                        --patch "@$volume_file" --mode no-reboot 2>&1; then
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
            continue
        fi

        echo "✅ MachineConfig och alla nodspecifika UserVolumeConfigs applicerade"

        echo "ℹ️  Noden startas om och hostname kommer att sättas."
        yq -i -o y '.nodes[] |= select(.name == "'$node_name'") | .initialized = true' nodes.yaml 2>/dev/null || \
        yq -i '.nodes[] |= select(.name == "'$node_name'") | .initialized = true' nodes.yaml 2>/dev/null || true

        echo "-----------------------------"
    done

    rm -rf "$config_dir"

    if [ -z "$target_node_name" ]; then
        message="Konfiguration har applicerats på alla noder."
    else
        message="Konfiguration har applicerats på noden $target_node_name."
    fi
    echo "$message"
    rm -f secrets.yaml
}

main_talos_health() {
    controlplanes=$(yq '.nodes[] | select(.role == "controlplane") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    workers=$(yq '.nodes[] | select(.role == "worker") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    echo "$controlplanes"
    echo "$workers"
    talosctl health -n 10.10.10.10
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
