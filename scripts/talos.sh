#!/bin/bash

# Converted from talos.nu

main_talos_dashboard() {
    ip="${1:-10.10.10.11}"
    nodes=$(yq '.nodes[] | select(.initialized == true) | .name' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    nodesString="${nodes%,}"
    talosctl dashboard -n "$nodesString"
}

main_talos_upgrade() {
    latestVersions=$(curl -s "https://api.github.com/repos/siderolabs/talos/releases?per_page=5" | jq -r '.[].tag_name')
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
    schematicID=$(yq ".nodes[] | select(.name == \"$selectedNodesString\") | .talos-id" /home/simon/repos/infrastructure/talos/nodes.yaml | head -1)
    echo "$schematicID"
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

    nodes=$(yq '.nodes[]' nodes.yaml)
    cluster_name="cluster1"
    endpoint="https://10.10.10.10:6443"
    config_dir="generated"

    if [ -z "$nodnamn" ]; then
        echo "Uppdaterar alla noder..."
        target_nodes="$nodes"
    else
        found_node=$(echo "$nodes" | yq "select(.name == \"$nodnamn\")")
        if [ -z "$found_node" ]; then
            echo "Ingen nod med namn $nodnamn hittades."
            return
        fi
        echo "Uppdaterar endast noden $nodnamn..."
        target_nodes="$found_node"
    fi

    if [ -d "$config_dir" ]; then
        rm -rf "$config_dir"
    fi
    mkdir "$config_dir"

    echo "$target_nodes" | while read -r node; do
        node_name=$(echo "$node" | yq '.name')
        node_ip=$(echo "$node" | yq '.ip')
        echo "Bearbetar nod: $node_name med IP $node_ip"

        nodePatches=$(echo "$node" | yq '.patches[]' | sed 's/^/--config-patch=@patches\//' | tr '\n' ' ')

        if [ "$nodePatches" = "--config-patch=@patches/" ]; then
            echo "Inga patchar hittades för noden $node_ip"
            nodePatches=""
        else
            echo "Patchar: $nodePatches"
        fi

        output_types="controlplane,worker,talosconfig"

        base_cmd="talosctl gen config $cluster_name $endpoint --output-types=$output_types --with-docs=false --with-examples=false --config-patch-control-plane=@patches/controlplane.yaml --config-patch-worker=@patches/worker.yaml -o $config_dir --with-secrets=secrets.yaml --force --config-patch=@patches/all.yaml"

        role=$(echo "$node" | yq '.role')
        if [ "$role" = "worker" ]; then
            base_cmd="$base_cmd --config-patch-worker=@patches/disks/$node_name.yaml"
        fi

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

        initialized=$(echo "$node" | yq '.initialized')
        if [ "$initialized" = "false" ]; then
            echo "Noden $node_ip är inte initialiserad, applicerar konfigurationen."
            talosctl apply-config --insecure --nodes "$node_ip" --file "$config_file"
        else
            echo "Noden $node_ip är redan initialiserad, applicerar konfigurationen."
            talosctl --talosconfig talosconfig apply-config --nodes "$node_ip" --file "$config_file"
            echo "klart"
        fi

        echo "Namnger noden $node_ip till $node_name"
        talosctl --talosconfig talosconfig patch mc -p "{\"machine\":{\"network\":{\"hostname\":\"$node_name\"}}}" -n "$node_ip"

        echo "-----------------------------"
    done

    if [ -z "$nodnamn" ]; then
        message="Konfiguration har applicerats på alla noder."
    else
        message="Konfiguration har applicerats på noden $nodnamn."
    fi
    echo "$message"
    rm -f secrets.yaml
    rm -rf "$config_dir"
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

main_talos_reboot_all() {
    controlplanes=$(yq '.nodes[] | select(.role == "controlplane") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    workers=$(yq '.nodes[] | select(.role == "worker") | .ip' /home/simon/repos/infrastructure/talos/nodes.yaml | tr '\n' ',')
    nodes="${controlplanes}${workers}"
    talosctl reboot -n "$nodes"
}