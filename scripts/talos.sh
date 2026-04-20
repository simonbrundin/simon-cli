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
    schematicID=$(yq ".nodes[] | select(.name == \"$selectedNodesString\") | .\"talos-id\"" /home/simon/repos/infrastructure/talos/nodes.yaml | head -1 | tr -d '"')

    if [ -z "$schematicID" ]; then
        echo "❌ Fel: Kunde inte hämta talos-id för nod $selectedNodesString"
        echo "   Kontrollera att noden finns i nodes.yaml"
        return 1
    fi

    echo "🔧 Uppgraderar nod $selectedNodesString med talos-id: $schematicID"
    echo "talosctl upgrade --image factory.talos.dev/installer/$schematicID:$selectedVersion -n $selectedNodesString"
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

        nodePatches=$(yq ".nodes[] | select(.name == \"$node_name\") | .patches[]" nodes.yaml 2>/dev/null | sed 's/^/--config-patch=@patches\//' | tr '\n' ' ')

        if [ "$nodePatches" = "--config-patch=@patches/" ]; then
            echo "Inga patchar hittades för noden $node_ip"
            nodePatches=""
        else
            echo "Patchar: $nodePatches"
        fi

        # Kontrollera om patch-filen innehåller diskSelector
        node_patch_file="patches/nodes/$node_name.yaml"
        needs_disk_reinstall=false
        disk_selector_matches=false
        
        if [ -f "$node_patch_file" ]; then
            if grep -q "diskSelector:" "$node_patch_file" 2>/dev/null; then
                patch_disk_serial=$(grep "serial:" "$node_patch_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
                
                if [ -n "$patch_disk_serial" ]; then
                    # Hämta nodens config och kolla disk/diskSelector
                    current_machine_config=$(talosctl --talosconfig talosconfig get mc v1alpha1 -n "$node_ip" -o yaml 2>/dev/null)
                    get_result=$?
                    config_lines=$(echo "$current_machine_config" | wc -l)
                    
                    # Om get mc lyckades OCH returnerar data - kolla disk:
                    if [ $get_result -eq 0 ] && [ "$config_lines" -gt 2 ]; then
                        # Om disk: INTE finns i config, är diskSelector aktiv (ingen upgrade behövs)
                        if ! echo "$current_machine_config" | grep -q "^[[:space:]]*disk:"; then
                            needs_disk_reinstall=false
                            disk_selector_matches=true
                            echo "ℹ️  diskSelector aktiv (ingen disk: i config) - hoppar över upgrade"
                        else
                            needs_disk_reinstall=true
                            echo "ℹ️  disk: finns i config - kör upgrade"
                        fi
                    else
                        # Noden nere eller fel - kör upgrade för säkerhets skull
                        needs_disk_reinstall=true
                        echo "ℹ️  Kan inte kontrollera nodens config - kör upgrade för säkerhets skull"
                    fi
                fi
            fi
        fi

        output_types="controlplane,worker,talosconfig"

        base_cmd="talosctl gen config $cluster_name $endpoint --output-types=$output_types --with-docs=false --with-examples=false --config-patch-control-plane=@patches/controlplane.yaml -o $config_dir --with-secrets=secrets.yaml --force --config-patch=@patches/all.yaml"

        full_cmd="$base_cmd $nodePatches"

        echo "Kör kommando: $full_cmd"
        eval "$full_cmd"
        echo "Genererar konfiguration för noden $node_ip"

        sleep 2

        config_file="$config_dir/$role.yaml"

        if [ ! -f "$config_file" ]; then
            echo "FEL: Konfigurationsfilen $config_file skapades INTE!"
            continue
        fi

        # Ta bort hostname från config så vi kan sätta det efter apply
        # Använd yq för att ta bort HostnameConfig dokumentet säkert
        if command -v yq &> /dev/null; then
            yq 'select(.kind != "HostnameConfig")' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
        fi

        # Kontrollera om noden har konfigurerade patches i nodes.yaml
        node_patches_list=$(yq ".nodes[] | select(.name == \"$node_name\") | .patches[]" nodes.yaml 2>/dev/null)
        
        if [ -n "$node_patches_list" ]; then
            node_patch="patches/nodes/$node_name.yaml"
            if [ -f "$node_patch" ] && [ -s "$node_patch" ]; then
              if grep -v '^#' "$node_patch" | grep -v '^[[:space:]]*$' | grep -q .; then
                echo "Applicerar node-specifik patch: $node_patch"
                talosctl machineconfig patch "$config_file" --patch "@$node_patch" -o "$config_file.tmp"
                if [ -f "$config_file.tmp" ]; then
                  mv "$config_file.tmp" "$config_file"
                  echo "✅ Node-patch applicerad"
                fi
              fi
            fi
        fi

        # Om diskSelector finns i patch, ta bort 'disk' för att undvika konflikt
        # Hoppa över om disk_selector_matches redan är true ELLER diskSelector finns i config-filen
        if [ "$needs_disk_reinstall" = "true" ] && [ "$disk_selector_matches" != "true" ]; then
            if command -v yq &> /dev/null; then
                # Kolla BÅDE disk OCH diskSelector
                has_disk=$(yq '.machine.install.disk' "$config_file" 2>/dev/null | grep -q 'null' && echo "no" || echo "yes")
                has_disk_selector=$(yq '.machine.install.diskSelector' "$config_file" 2>/dev/null | grep -q 'null' && echo "no" || echo "yes")
                
                if [ "$has_disk" = "no" ] && [ "$has_disk_selector" = "no" ]; then
                    echo "ℹ️  Varken disk eller diskSelector - lägger till diskSelector från patch"
                elif [ "$has_disk" = "no" ] && [ "$has_disk_selector" = "yes" ]; then
                    echo "ℹ️  diskSelector finns redan i config - behåller den"
                elif [ "$has_disk" = "yes" ] && [ "$has_disk_selector" = "yes" ]; then
                    echo "🧹 Tar bort disk (diskSelector finns också i config)..."
                    yq 'del(.machine.install.disk)' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
                    echo "✅ disk borttagen, diskSelector behålls"
                else
                    echo "🧹 Tar bort disk från config..."
                    yq 'del(.machine.install.disk)' "$config_file" > "$config_file.tmp" && mv "$config_file.tmp" "$config_file"
                    echo "✅ disk borttagen"
                fi
            fi
        fi

        # Kontrollera nodens verkliga status med talosctl get machinestatus
        echo "Kontrollerar nodens status..."
        node_in_maintenance=false
        node_initialized=false
        
        # Använd talosctl get machinestatus för att avgöra nodens tillstånd
        machine_status=$(talosctl --talosconfig talosconfig get machinestatus -n "$node_ip" 2>&1)
        
        if echo "$machine_status" | grep -q "maintenance"; then
            node_in_maintenance=true
            echo "ℹ️  Noden är i maintenance mode (ej initialiserad)"
        elif echo "$machine_status" | grep -q "running"; then
            node_initialized=true
            echo "ℹ️  Noden är initialiserad och medlem i klustret"
        else
            # Fallback till gammal metod
            if talosctl --talosconfig talosconfig apply-config --nodes "$node_ip" --dry-run --file "$config_file" >/dev/null 2>&1; then
                node_initialized=true
                echo "ℹ️  Noden är initialiserad och medlem i klustret"
            else
                echo "ℹ️  Kan inte avgöra nodens status, försöker med initierad..."
                node_initialized=true
            fi
        fi
#   talosctl get machinestatus -n 10.10.10.29 --insecure
# NODE   NAMESPACE   TYPE            ID        VERSION   STAGE         READY
#        runtime     MachineStatus   machine   5         maintenance   true
#
        if [ "$node_in_maintenance" = "true" ]; then
            echo "📝 Applicerar konfiguration i maintenance mode..."
            if talosctl apply-config --insecure --nodes "$node_ip" --file "$config_file" --config-patch "{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}"; then

                echo "✅ Konfiguration applicerad med hostname $node_name!"
                echo "ℹ️  Noden startas om och hostname kommer att sättas."
                yq -i ".nodes[] |= select(.name == \"$node_name\").initialized = true" nodes.yaml
                # Uppdatera nodes.yaml
                yq -i ".nodes[] |= select(.name == \"$node_name\").initialized = true" nodes.yaml
            else
                echo "❌ Kunde inte applicera konfiguration"
            fi
        elif [ "$node_initialized" = "true" ]; then
            echo "Noden $node_ip är redan initialiserad, applicerar konfigurationen."
            
            # Om diskSelector finns i patch, använd patch machineconfig för att behålla diskSelector
            # HOPPA ÖVER HELT om disk_selector_matches redan är true
            if [ "$disk_selector_matches" = "true" ]; then
                echo "ℹ️  diskSelector aktiv - endast applicera konfig utan upgrade"
                talosctl --talosconfig talosconfig apply-config --nodes "$node_ip" --file "$config_file" --config-patch "{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}" --mode no-reboot
                echo "✅ Konfiguration applicerad"
            elif [ "$needs_disk_reinstall" = "true" ]; then
                echo "⚠️  Maskininstalldisk har ändrats i konfigurationen (diskSelector)"
                echo "   Detta KRÄVER omstart av noden för att diskSelector ska användas."
                echo ""
                
                # Skapa en enkel JSON patch som sätter disk till null och lägger till diskSelector
                local disk_serial
                disk_serial=$(grep "serial:" "patches/nodes/$node_name.yaml" | head -1 | awk '{print $2}' | tr -d '"')
                
                if [ -n "$disk_serial" ]; then
                    echo "📝 Patchar machineconfig med diskSelector (serial: $disk_serial)..."
                    
                    # Först: lägg till diskSelector
                    if talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                        --patch '[{"op": "add", "path": "/machine/install/diskSelector/serial", "value": "'"$disk_serial"'"}]' \
                        --mode no-reboot 2>/dev/null; then
                        echo "✅ diskSelector tillagd"
                    else
                        # Om det misslyckas, försök med replace (om diskSelector redan finns)
                        talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                            --patch '[{"op": "replace", "path": "/machine/install/diskSelector/serial", "value": "'"$disk_serial"'"}]' \
                            --mode no-reboot 2>/dev/null || true
                    fi
                    
                    # Sen: ta bort disk (om den finns)
                    talosctl --talosconfig talosconfig patch machineconfig --nodes "$node_ip" \
                        --patch '[{"op": "remove", "path": "/machine/install/disk"}]' \
                        --mode no-reboot 2>/dev/null || true
                    
                    # Säkerställ att hostname appliceras FÖRE upgrade
                    echo "📝 Applicerar hostname: $node_name..."
                    talosctl --talosconfig talosconfig apply-config --nodes "$node_ip" \
                        --file "$config_file" \
                        --config-patch "{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}" \
                        --mode no-reboot
                    
                    # Hämta talos-id (schematic) för att köra upgrade med rätt image
                    schematicID=$(yq ".nodes[] | select(.name == \"$node_name\") | .\"talos-id\"" nodes.yaml 2>/dev/null | tr -d '"')
                    
                    if [ -n "$schematicID" ] && [ "$schematicID" != "null" ]; then
                        echo "📦 Kör upgrade med schematic $schematicID (installerar extensions + uppdaterar diskSelector)..."
                        talosctl --talosconfig talosconfig upgrade \
                            --image "factory.talos.dev/installer/$schematicID:v1.12.5" \
                            --nodes "$node_ip" \
                            --preserve 2>/dev/null || \
                        talosctl --talosconfig talosconfig upgrade \
                            --image "ghcr.io/siderolabs/installer:v1.12.5" \
                            --nodes "$node_ip" \
                            --preserve 2>/dev/null || \
                        talosctl --talosconfig talosconfig reboot -n "$node_ip" 2>/dev/null
                        
                        echo "✅ Upgrade/reboot påbörjad för $node_name"
                        echo "   Noden kommer att starta om med diskSelector och extensions aktiverade"
                    else
                        echo "⚠️  Kunde inte hitta talos-id, kör vanlig reboot..."
                        talosctl --talosconfig talosconfig reboot -n "$node_ip" 2>/dev/null
                        echo "✅ Noden $node_name kommer att starta om och använda diskSelector."
                    fi
                else
                    echo "⚠️  Kunde inte hitta diskSelector serial i patch-filen"
                fi
            else
                # Vanlig uppdatering utan disk-ändring
                if talosctl --talosconfig talosconfig apply-config --nodes "$node_ip" --file "$config_file" --config-patch "{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}"; then
                    echo "✅ Konfiguration applicerad med hostname $node_name"
                    echo "ℹ️  Obs: För att uppdatera diskkonfiguration (UserVolumes), krävs omstart av noden"
                else
                    echo "❌ Kunde inte applicera konfiguration"
                fi
            fi
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
    # rm -rf "$config_dir"
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
