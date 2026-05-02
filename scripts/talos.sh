#!/bin/bash

# Converted from talos.nu

export TALOSCONFIG=/home/simon/.talos/config

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
    latestVersions=$(curl -s "https://api.github.com/repos/siderolabs/talos/releases?per_page=15" | jq -r '.[].tag_name')
    echo -e "\033[34mVilken version vill du installera?\033[0m"
    selectedVersion=$(fzfSelect "$latestVersions")

    echo -e "\033[34mHur loggar du in mot klustret?\033[0m"
    loginMethods=("Teleport" "Certifikat")
    selectedMethod=$(fzfSelect "${loginMethods[@]}")

    if [ "$selectedMethod" = "Certifikat" ]; then
        nodes=$(kubectl get nodes --kubeconfig "/tmp/kubeconfig-certificate" | awk 'NR>1 {print $1}')
    else
        nodes=$(kubectl get nodes | awk 'NR>1 {print $1}')
    fi

    echo -e "\033[34mVilka noder vill du uppdatera?\033[0m"
    selectedNodes=$(fzfSelect "$nodes")
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
    nodnamn="$1"
    cd /home/simon/repos/infrastructure/talos || return

    mkdir -p ~/.op
    chmod 700 ~/.op
    op signin --raw > ~/.op/session
    op read op://talos/secrets/secrets.yaml -o secrets.yaml -f
    op read op://talos/talosconfig/talosconfig -o talosconfig -f
    chmod 666 secrets.yaml talosconfig

    cluster_name="cluster1"
    endpoint="https://10.10.10.10:6443"
    config_dir="generated"
    controlplane_ip=$(yq '.nodes[] | select(.role == "controlplane") | .ip' nodes.yaml | head -1 | tr -d '"')

    # Använd systemets talosconfig om den finns och fungerar
    echo "Kontrollerar talosconfig..."
    if [ -f "$HOME/.talos/config" ]; then
        echo "Använder systemets talosconfig från ~/.talos/config"
        cp "$HOME/.talos/config" ./talosconfig
        chmod 666 talosconfig
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
    if [ -z "$nodnamn" ]; then
        echo "Uppdaterar alla noder..."
        node_names=$(yq '.nodes[].name' nodes.yaml)
    else
        if ! yq ".nodes[] | select(.name == \"$nodnamn\")" nodes.yaml | grep -q .; then
            echo "Ingen nod med namn $nodnamn hittades."
            return
        fi
        echo "Uppdaterar endast noden $nodnamn..."
        node_names="$nodnamn"
    fi

    if [ -d "$config_dir" ]; then
        rm -rf "$config_dir"
    fi
    mkdir "$config_dir"

    echo "$node_names" | while IFS= read -r node_name; do
        # Get node data using the name
        node_name=$(echo "$node_name" | tr -d '"')
        node_ip=$(yq ".nodes[] | select(.name == \"$node_name\") | .ip" nodes.yaml | tr -d '"')
        role=$(yq ".nodes[] | select(.name == \"$node_name\") | .role" nodes.yaml | tr -d '"')
        initialized=$(yq ".nodes[] | select(.name == \"$node_name\") | .initialized" nodes.yaml | tr -d '"')
        
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
        node_has_tls_error=false
        node_in_maintenance=false

        if ! talosctl --talosconfig talosconfig version -n "$node_ip" --short >/dev/null 2>&1; then
            tls_error=$(talosctl --talosconfig talosconfig version -n "$node_ip" --short 2>&1 | grep -i "certificate\|tls\|auth" || echo "")
            if [ -n "$tls_error" ]; then
                node_has_tls_error=true
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

            # Hämta diskSelector serial om den finns i patch-filen
            local disk_serial=""
            if [ -f "patches/nodes/$node_name.yaml" ]; then
                disk_serial=$(grep "serial:" "patches/nodes/$node_name.yaml" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
            fi

            # Applicera UserVolumeConfigs separat (Talos stödjer inte multi-doc patch)
            # Kolla i ny struktur: patches/workers/<nod>/disks/*.yaml
            local disk_dir="patches/workers/$node_name/disks"
            if [ -d "$disk_dir" ]; then
                volume_count=$(find "$disk_dir" -name "*.yaml" 2>/dev/null | wc -l | tr -d ' ')
                if [ "$volume_count" -gt 0 ]; then
                    echo "📝 Applicerar UserVolumeConfigs från $disk_dir..."

                    applied=0
                    failed=0
                    for volume_file in "$disk_dir"/*.yaml; do
                        volume_name=$(yq -r '.name' "$volume_file" 2>/dev/null)

                        if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                            --patch "@$volume_file" --mode no-reboot 2>/dev/null; then
                            echo "  ✅ $volume_name applicerad"
                            applied=$((applied + 1))
                        else
                            echo "  ⚠️ $volume_name misslyckades"
                            failed=$((failed + 1))
                        fi
                    done

                    if [ $failed -eq 0 ]; then
                        echo "  ✅ UserVolumeConfigs applicerade"
                    else
                        echo "  ⚠️ $failed UserVolumeConfig(s) misslyckades"
                    fi
                fi
            fi

            # Applicera hostname separat (JSON6902 patch)
            echo "📝 Applicerar hostname: $node_name..."
            if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                --patch "[{\"op\": \"add\", \"path\": \"/machine/network/hostname\", \"value\": \"$node_name\"}]" \
                --mode no-reboot 2>&1 | grep -v "skipped"; then
                echo "✅ Hostname applicerad"
            else
                echo "  (hostname är redan korrekt eller patchade inte vid omstart)"
            fi

            # Applicera diskSelector separat
            if [ -n "$disk_serial" ]; then
                echo "📝 Lägger till diskSelector (serial: $disk_serial)..."
                talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                    --patch '[{"op": "add", "path": "/machine/install/diskSelector/serial", "value": "'"$disk_serial"'"}]' \
                    --mode no-reboot 2>/dev/null || \
                talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                    --patch '[{"op": "replace", "path": "/machine/install/diskSelector/serial", "value": "'"$disk_serial"'"}]' \
                    --mode no-reboot 2>/dev/null || true
                echo "✅ diskSelector applicerad"
            fi

            # Installera extensions om de inte redan finns
            if [ "$node_needs_extension_upgrade" = true ] && [ -n "$talos_schematic_id" ] && [ "$talos_schematic_id" != "null" ]; then
                echo "📝 Installerar extensions via upgrade..."
                echo "  Installerar med schematic: $talos_schematic_id"
                echo "🔗 https://factory.talos.dev/image/${talos_schematic_id}/${talos_version}/metal-${arch}.raw.xz"
                
                # Hämta aktuell Talos-version med v-prefix
                local talos_version
                talos_version=$(talosctl --talosconfig talosconfig version -n "$node_ip" 2>/dev/null | grep "Tag:" | head -1 | awk '{print $2}' || echo "")
                
                if [ -z "$talos_version" ]; then
                    talos_version="vlatest"
                fi
                
                echo "  Talos version: $talos_version"
                
                if talosctl upgrade --image "factory.talos.dev/installer/$talos_schematic_id:$talos_version" -n "$node_ip" --wait --timeout 10m 2>&1; then
                    echo "  ✅ Extensions installerade (Talos upgrade med schematic $talos_schematic_id)"
                else
                    echo "  ⚠️ Upgrade misslyckades med version $talos_version"
                fi
            fi

            echo "-----------------------------"
            continue
        fi

        # För noder i maintenance mode, generera konfiguration
        echo "📝 Installerar noden $node_name i maintenance mode..."

        output_types="controlplane,worker,talosconfig"

        base_cmd="talosctl gen config $cluster_name $endpoint --output-types=$output_types --with-docs=false --with-examples=false --config-patch-control-plane=@patches/controlplane.yaml -o $config_dir --with-secrets=secrets.yaml --force --config-patch=@patches/all.yaml"

        full_cmd="$base_cmd"

        echo "Kör kommando: $full_cmd"
        eval "$full_cmd"
        echo "Genererar konfiguration för noden $node_ip"

        sleep 2

        config_file="$config_dir/$role.yaml"

        if [ ! -f "$config_file" ]; then
            echo "FEL: Konfigurationsfilen $config_file skapades INTE!"
            echo "-----------------------------"
            continue
        fi

        # Ta bort hostname från config så vi kan sätta det efter apply
        if command -v yq &> /dev/null; then
            yq 'select(.kind != "HostnameConfig")' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
        fi

        # Om diskSelector finns i patch, ta bort 'disk' för att undvika konflikt
        if [ -f "patches/nodes/$node_name.yaml" ]; then
            if command -v yq &> /dev/null; then
                has_disk=$(yq '.machine.install.disk' "$config_file" 2>/dev/null | grep -q 'null' && echo "no" || echo "yes")
                has_disk_selector=$(yq '.machine.install.diskSelector' "$config_file" 2>/dev/null | grep -q 'null' && echo "no" || echo "yes")

                if [ "$has_disk" = "yes" ] && [ "$has_disk_selector" = "yes" ]; then
                    echo "🧹 Tar bort disk (diskSelector finns också i config)..."
                    yq 'del(.machine.install.disk)' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
                    echo "✅ disk borttagen, diskSelector behålls"
                elif [ "$has_disk" = "yes" ]; then
                    echo "🧹 Tar bort disk från config..."
                    yq 'del(.machine.install.disk)' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
                    echo "✅ disk borttagen"
                fi
            fi
        fi

        # Bygg ihop config-patch med hostname och diskSelector
        config_patch="{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}"
        if [ "$node_has_disk_selector" = "true" ] && [ -n "$node_disk_selector_patch" ]; then
            config_patch="$node_disk_selector_patch"
        fi

        echo "📝 Applicerar konfiguration på $node_name..."
        if talosctl apply-config --insecure --nodes "$node_ip" --file "$config_file" --config-patch "$config_patch"; then

            echo "✅ Konfiguration applicerad med hostname $node_name!"
            echo "ℹ️  Noden startas om och hostname kommer att sättas."
            yq -i ".nodes[] |= select(.name == \"$node_name\") | .initialized = true" nodes.yaml
        else
            echo "❌ Kunde inte applicera konfiguration"
        fi

        echo "-----------------------------"
    done

    if [ -z "$nodnamn" ]; then
        message="Konfiguration har applicerats på alla noder."
    else
        message="Konfiguration har applicerats på noden $nodnamn."
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
