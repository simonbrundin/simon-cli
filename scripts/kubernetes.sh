#!/bin/bash

# Converted from kubernetes.nu

main_k() {
    # simon.sh kubernetes "$@"
    echo "Kubernetes alias"
}

main_kubernetes_login_certificate() {
    clustername="${1:-}"

    echo -e "\033[34m🔐 Loggar in i 1Password...\033[0m"

    # Ensure ~/.op directory exists with correct permissions
    mkdir -p ~/.op
    chmod 700 ~/.op

    # Check for existing valid session first
    if [ -f ~/.op/session ] && [ -s ~/.op/session ]; then
        export OP_SESSION_TOKEN=$(cat ~/.op/session)
        if ! op whoami &>/dev/null; then
            # Session expired, get new one
            op signin --raw > ~/.op/session 2>/dev/null
            export OP_SESSION_TOKEN=$(cat ~/.op/session)
        fi
    else
        # No session file, create new session
        op signin --raw > ~/.op/session 2>/dev/null
        export OP_SESSION_TOKEN=$(cat ~/.op/session)
    fi

    if ! op whoami &>/dev/null; then
        echo -e "\033[31m[ERROR]\033[0m Kunde inte logga in i 1Password."
        rm -f ~/.op/session
        return 1
    fi

    echo -e "\033[34m📄 Hämtar kubeconfig...\033[0m"
    kubeconfig_content=$(op read "op://Talos/kubeconfig/kubeconfig" 2>/dev/null)

    if [ -z "$kubeconfig_content" ]; then
        echo -e "\033[31m[ERROR]\033[0m Kunde inte hämta kubeconfig från 1Password."
        echo -e "\033[33mKontrollera:\033[0m"
        echo -e "  1. Att 'Talos/kubeconfig/kubeconfig' finns i ditt valv"
        echo -e "  2. Att du har åtkomst till detta objekt"
        return 1
    fi

    temp_kubeconfig="/tmp/kubeconfig-certificate"
    echo -e "\033[34mSparar kubeconfig till:\033[0m \033[32m$temp_kubeconfig\033[0m"
    echo "$kubeconfig_content" > "$temp_kubeconfig"

    if kubectl get nodes --kubeconfig "$temp_kubeconfig" &> /dev/null; then
        bashrc="$HOME/.bashrc"
        if grep -q "^export KUBECONFIG=" "$bashrc"; then
            sed -i "s|^export KUBECONFIG=.*|export KUBECONFIG=$temp_kubeconfig|" "$bashrc"
        else
            echo "export KUBECONFIG=$temp_kubeconfig" >> "$bashrc"
        fi
        export KUBECONFIG="$temp_kubeconfig"
        echo -e "\033[32mInloggning lyckades!\033[0m"
    else
        echo -e "\033[31mInloggning misslyckades – kontrollera certifikat eller nätverk.\033[0m"
    fi
}

main_kubernetes_login_teleport() {
    clustername="${1:-}"

    bash -c "tsh login --proxy=teleport.simonbrundin.com:443 --user=admin --auth=passwordless teleport.simonbrundin.com"
    echo -e "\033[34mtsh login lyckades!\033[0m"
    bash -c "export kubeconfig=${HOME?}/teleport-kubeconfig.yaml"
    echo -e "\033[34mexport kubeconfig lyckades!\033[0m"
    bash -c "unset TELEPORT_PROXY"
    bash -c "unset TELEPORT_CLUSTER"
    bash -c "unset TELEPORT_KUBE_CLUSTER"
    bash -c "unset KUBECONFIG"
    export KUBECONFIG=""
    bash -c "tsh kube login cluster1"
    echo -e "\033[34mtsh kube login lyckades!\033[0m"

    # Avsluta allt på port 8443
    echo -e "\033[33mRensar port 8443...\033[0m"
    fuser -k 8443/tcp 2>/dev/null || true
    for i in {1..30}; do nc -z localhost 8443 2>/dev/null || break; sleep 0.1; done
    echo -e "\033[32mPort 8443 är redo!\033[0m"

    bash -c "tsh proxy kube -p 8443 &"
    export KUBECONFIG="/home/simon/.tsh/keys/teleport.simonbrundin.com/admin-kube/teleport.simonbrundin.com/localproxy-8443-kubeconfig"
    echo -e "\033[32minloggning lyckades!\033[0m"
    sleep 2
    kubectl get nodes
}

main_kubernetes_dashboard() {
    k9s -c 'pods' -A --logoless --headless
}

main_kubernetes_approve_csr() {
    kubectl get csr --no-headers | awk '/Pending/ {print $1}' | xargs -r kubectl certificate approve
    echo -e "\033[32mAlla Pending CSR har godkänts\033[0m"
}

main_kubernetes_delete_pod() {
    # Lista namespaces
    namespaces=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name')
    selected_namespace=$(fzfSelect "$namespaces")
    if [ -z "$selected_namespace" ]; then
        echo "❌ Inget namespace valt. Avbryter."
        return
    fi
    # Lista pods
    pods=$(kubectl get pods -n "$selected_namespace" -o json | jq -r '.items[].metadata.name')
    selected_pod=$(fzfSelect "$pods")
    if [ -z "$selected_pod" ]; then
        echo "❌ Ingen pod vald. Avbryter."
        return
    fi
    kubectl delete pod "$selected_pod" -n "$selected_namespace" --grace-period=0 --force
}

main_kubernetes_debug() {
    name="${1:-}"

    # Simplified: get pods not running
    pods=$(kubectl get pods -A | awk 'NR>1 && $4 != "Running" && $2 ~ /'"$name"'/ {print $1"/"$2" - "$4}')

    if [ -z "$pods" ]; then
        echo "Inga poddar hittades"
        return
    fi

    selected=$(echo "$pods" | fzfSelect)
    if [ -z "$selected" ]; then
        echo "Ingen pod vald."
        return
    fi

    namespace=$(echo "$selected" | cut -d'/' -f1)
    pod_name=$(echo "$selected" | cut -d'/' -f2 | cut -d' ' -f1)

    status=$(kubectl get pod -n "$namespace" "$pod_name" -o yaml | yq '.status')
    describe=$(kubectl describe pod -n "$namespace" "$pod_name")
    echo -e "$describe\n\nStatus:\n$status" | cb
    echo -e "\033[32mKopierat till Clipboard\033[0m"
}

main_kubernetes_remove_finalizers() {
    # Steg 1: Välj namespace
    namespaces=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name')
    selected_namespace=$(fzfSelect "$namespaces")

    if [ -z "$selected_namespace" ]; then
        echo "❌ Inget namespace valt. Avbryter."
        return
    fi

    # Steg 2: Hämta resurstyper
    resource_types=$(kubectl api-resources --namespaced=true --verbs=list -o name)

    components=()
    for type in $resource_types; do
        items=$(kubectl get "$type" -n "$selected_namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        for item in $items; do
            components+=("$type/$item")
        done
    done

    selected_components=$(fzfSelect "${components[@]}")

    if [ -z "$selected_components" ]; then
        echo "❌ Inga resurser valda. Avbryter."
        return
    fi

    for selected_component in $selected_components; do
        kind=$(echo "$selected_component" | cut -d'/' -f1)
        name=$(echo "$selected_component" | cut -d'/' -f2)

        echo "🔍 Kollar $kind/$name..."

        has_finalizers=$(kubectl get "$kind" "$name" -n "$selected_namespace" -o json | jq -r '.metadata.finalizers | length > 0')

        if [ "$has_finalizers" != "true" ]; then
            echo "ℹ️  $kind/$name har inga finalizers."
        else
            echo "⚙️  Tar bort finalizers från $kind/$name..."
            kubectl patch "$kind" "$name" -n "$selected_namespace" -p '{"metadata":{"finalizers":null}}' --type=merge
            new_finalizers=$(kubectl get "$kind" "$name" -n "$selected_namespace" -o json 2>/dev/null | jq -r '.metadata.finalizers | length' 2>/dev/null || echo "0")
            if [ "$new_finalizers" -eq 0 ]; then
                echo "✅ Finalizers borttagna!"
            else
                echo "⚠️  Kunde inte bekräfta att finalizers tagits bort."
            fi
        fi
    done
}

main_kubernetes_deleting() {
    kubectl get all,configmaps,secrets,pvc --all-namespaces -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.kind)/\(.metadata.name) (Namespace: \(.metadata.namespace))"'
}

main_kubernetes_terminating() {
    kubectl api-resources --verbs=list --namespaced=true -o name | xargs -I {} kubectl get {} -n rook-ceph -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.kind)/\(.metadata.name)"'
}

main_kubernetes_remove_selected() {
    # Similar to remove_finalizers, but delete
    namespaces=$(kubectl get namespaces -o json | jq -r '.items[].metadata.name')
    selected_namespace=$(fzfSelect "$namespaces")

    if [ -z "$selected_namespace" ]; then
        echo "❌ Inget namespace valt. Avbryter."
        return
    fi

    resource_types=$(kubectl api-resources --namespaced=true --verbs=list -o name)

    components=()
    for type in $resource_types; do
        items=$(kubectl get "$type" -n "$selected_namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        for item in $items; do
            components+=("$type/$item")
        done
    done

    selected_components=$(fzfSelect "${components[@]}")

    if [ -z "$selected_components" ]; then
        echo "❌ Inga resurser valda. Avbryter."
        return
    fi

    for selected_component in $selected_components; do
        kind=$(echo "$selected_component" | cut -d'/' -f1)
        name=$(echo "$selected_component" | cut -d'/' -f2)

        echo "🗑️  Raderar $kind/$name i namespace $selected_namespace..."
        kubectl delete "$kind" "$name" -n "$selected_namespace"
    done

    echo "✅ Klart!"
}

main_kubernetes_longhorn_test() {
    local selected_node="$1"
    
    if [ -z "$selected_node" ]; then
        nodes=$(kubectl get nodes -o json | jq -r '.items[].metadata.name')
        selected_node=$(fzfSelect "$nodes")
    fi
    
    if [ -z "$selected_node" ]; then
        echo "Ingen node vald"
        return 1
    fi
    
    echo -e "\033[34mVald node: \033[0m$selected_node\n"

    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    if [ ! -f "$nodes_yaml" ]; then
        echo -e "\033[31m❌ nodes.yaml not found: $nodes_yaml\033[0m"
        return 1
    fi

    local ip
    ip=$(yq -r ".nodes[] | select(.name == \"$selected_node\") | .ip" "$nodes_yaml")
    if [ -z "$ip" ] || [ "$ip" == "null" ]; then
        echo -e "\033[31m❌ IP not found for node: $selected_node\033[0m"
        return 1
    fi

    echo -e "\033[34mNode IP: \033[0m$ip\n"

    echo -e "\033[34mSystemdisk:\033[0m"
    local install_disk install_pretty_size disk_selector_output
    
    # Läs diskSelector från patch-filen (konfigurerad)
    local patch_file="$HOME/repos/infrastructure/talos/patches/nodes/$selected_node.yaml"
    local ds_serial ds_model ds_size
    if [ -f "$patch_file" ]; then
        ds_serial=$(grep "serial:" "$patch_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"' | tr -d "'")
        ds_model=$(grep "model:" "$patch_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
        ds_size=$(grep "size:" "$patch_file" 2>/dev/null | head -1 | awk '{print $2}' | tr -d '"')
    fi
    
    # Hämta installerad disk via systemdisks
    local sysdisk_line
    sysdisk_line=$(talosctl get systemdisks -n "$ip" 2>/dev/null)
    
    if echo "$sysdisk_line" | grep -q "system-disk"; then
        local sys_disk
        sys_disk=$(echo "$sysdisk_line" | grep "system-disk" | awk '{print $NF}')
        
        if [ -n "$sys_disk" ] && [ "$sys_disk" != "null" ]; then
            # Hämta disk info (storlek, modell, serial)
            local disk_info
            disk_info=$(talosctl get disks -n "$ip" -o json 2>/dev/null | jq -rs ".[] | select(.metadata.id == \"$sys_disk\") | .spec.pretty_size + \" \" + (.spec.model // .spec.dev_path)")
            
            if [ -n "$disk_info" ]; then
                local disk_serial
                disk_serial=$(talosctl get disks -n "$ip" -o json 2>/dev/null | jq -rs ".[] | select(.metadata.id == \"$sys_disk\") | .spec.serial // \"\"")

                if [ -n "$ds_serial" ]; then
                    if [ -n "$disk_serial" ] && [ "$disk_serial" != "null" ]; then
                        if [ "$ds_serial" = "$disk_serial" ]; then
                            echo -e "  \033[32m✓ Konfiguerad serial: $ds_serial (matchar installerad)\033[0m"
                            echo -e "  \033[32m  Installerad disk: $disk_info ($sys_disk)\033[0m"
                        else
                            echo -e "  \033[31m✗ Serial mismatch! Konfiguerad: $ds_serial, Installerad: $disk_serial\033[0m"
                            echo "  Installerad disk: $disk_info ($sys_disk)"
                        fi
                    else
                        echo -e "  \033[31m✗ Installerad disk saknar serial\033[0m"
                        echo "  Installerad disk: $disk_info ($sys_disk)"
                    fi
                else
                    echo -e "  \033[31m✗ Ingen serial konfigurerad i patch\033[0m"
                    echo "  Installerad disk: $disk_info ($sys_disk)"
                fi
            else
                echo "  Installerad disk: $sys_disk"
            fi
        fi
    else
        # Fallback: försök hämta från machineconfig
        local mc_output
        mc_output=$(talosctl get machineconfig -n "$ip" -o json 2>/dev/null)
        
        if [ -n "$mc_output" ] && [ "$mc_output" != "null" ]; then
            install_disk=$(echo "$mc_output" | jq -r '.spec' 2>/dev/null | yq '.machine.install.disk' 2>/dev/null | tr -d '"')
            
            if [ -n "$install_disk" ] && [ "$install_disk" != "null" ]; then
                local disk_info
                disk_info=$(talosctl get disks -n "$ip" -o json 2>/dev/null | jq -rs ".[] | select(.spec.dev_path == \"$install_disk\") | \"\(.spec.pretty_size) \(.spec.model // .spec.dev_path)\"")
                echo "  Installerad disk: $disk_info"
            else
                echo "  (ingen disk konfigurerad)"
            fi
        else
            echo "  (ingen disk konfigurerad)"
        fi
    fi

    echo -e "\033[34mInstallerade tillägg:\033[0m"
    local ext_output
    ext_output=$(talosctl get extensions -n "$ip" -o json 2>/dev/null)
    
    # Läs alltid från machineconfig för konfigurerade extensions
    local mc_output configured_ext
    mc_output=$(talosctl get machineconfig -n "$ip" -o json 2>/dev/null)
    configured_ext=$(echo "$mc_output" | jq -r '.spec' 2>/dev/null | yq '.machine.install.extensions[].image' 2>/dev/null | tr -d '"')

    # Visa konfigurerade och installerade extensions
    if [ -n "$configured_ext" ] && [ "$configured_ext" != "null" ]; then
        echo "$configured_ext" | while read -r ext; do
            [ -n "$ext" ] && echo "  - $ext (konfigurerad)"
        done
    fi
    
    # Visa även installerade extensions om dom finns och är olika
    if [ -n "$ext_output" ] && [ "$ext_output" != "null" ] && echo "$ext_output" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
        local installed_ext
        installed_ext=$(echo "$ext_output" | jq -sr '.[] | select(.spec != null) | .spec.metadata.name')
        if [ -n "$installed_ext" ]; then
            echo "$installed_ext" | while read -r ext; do
                if ! echo "$configured_ext" | grep -q "$ext"; then
                    echo "  - $ext (installerad)"
                fi
            done
        fi
    fi

    # Kontrollera om util-linux-tools och schematic är installerade
    local util_installed=false
    local schematic_installed=false
    
    # Kolla i installerade extensions (ext_output)
    if [ -n "$ext_output" ] && [ "$ext_output" != "null" ]; then
        local installed_names
        installed_names=$(echo "$ext_output" | jq -r '.. | if type == "object" and has("name") then .name else empty end' 2>/dev/null)
        if echo "$installed_names" | grep -qx "util-linux-tools"; then
            util_installed=true
        fi
        if echo "$installed_names" | grep -qx "schematic"; then
            schematic_installed=true
        fi
    fi
    
    # Kolla även i konfigurerade extensions (configured_ext)
    if [ -n "$configured_ext" ] && [ "$configured_ext" != "null" ]; then
        if echo "$configured_ext" | sed 's|.*/||' | sed 's|:.*||' | grep -qx "util-linux-tools"; then
            util_installed=true
        fi
        if echo "$configured_ext" | sed 's|.*/||' | sed 's|:.*||' | grep -qx "schematic"; then
            schematic_installed=true
        fi
    fi

    if [ "$util_installed" = true ] && [ "$schematic_installed" = true ]; then
        echo -e "  \033[32m✓ util-linux-tools och schematic är installerade\033[0m"
    else
        echo -e "  \033[31m✗ util-linux-tools och schematic är inte installerade\033[0m"
    fi
    
    if [ -z "$configured_ext" ] || [ "$configured_ext" = "null" ]; then
        echo "  Inga tillägg konfigurerade"
    fi

    echo -e "\033[34mDiskar och partitioner:\033[0m"
    local disk_output
    disk_output=$(talosctl get dv -n "$ip" -o json 2>/dev/null)
    if [ -n "$disk_output" ] && [ "$disk_output" != "null" ]; then
        local disks partitions
        disks=$(echo "$disk_output" | jq -sr '.[] | select(.spec.type == "disk") | "\(.metadata.id) \(.spec.dev_path)"')
        partitions=$(echo "$disk_output" | jq -sr '.[] | select(.spec.type == "partition") | "\(.metadata.id) \(.spec.dev_path)"')

        while IFS= read -r line; do
            [ -z "$line" ] && continue
            disk_name=$(echo "$line" | awk '{print $1}')
            disk_path=$(echo "$line" | awk '{print $2}')
            echo "$disk_name $disk_path"

            while IFS= read -r part_line; do
                [ -z "$part_line" ] && continue
                part_name=$(echo "$part_line" | awk '{print $1}')
                part_path=$(echo "$part_line" | awk '{print $2}')
                if [[ "$part_name" == "$disk_name"* ]] && [[ "$part_name" != "$disk_name" ]]; then
                    echo "  $part_name $part_path"
                fi
            done <<< "$partitions"
        done <<< "$disks"
    else
        echo "Inga diskar hittades"
    fi

    echo -e "\033[34mUserVolumes:\033[0m"
    local udc_status
    udc_status=$(talosctl get userdiskconfigstatuses -n "$ip" -o json 2>/dev/null)
    if [ -n "$udc_status" ] && [ "$udc_status" != "null" ]; then
        local ready torndown
        ready=$(echo "$udc_status" | jq -r '.spec.ready')
        torndown=$(echo "$udc_status" | jq -r '.spec.tornDown')

        if [ "$ready" = "true" ]; then
            local all_disks
            all_disks=$(talosctl get disks -n "$ip" -o json 2>/dev/null)
            if [ -n "$all_disks" ]; then
                local user_disks
                user_disks=$(echo "$all_disks" | jq -sr '.[] | select(.spec.transport == "usb" or .spec.transport == "iscsi" or .spec.transport == "nvme" or .spec.transport == "ata") | "  \(.spec.pretty_size) @ \(.spec.dev_path)"')
                if [ -n "$user_disks" ]; then
                    echo "$user_disks"
                else
                    echo "  Inga externa diskar"
                fi
            fi
        else
            echo "  UserVolumes inte redo"
        fi

        if [ "$torndown" = "true" ]; then
            echo "  (teardown)"
        fi
    else
        echo "  Inga UserVolumes konfigurerade"
    fi
}

main_kubernetes_iscsi_health() {
    echo -e "\n\033[34m7. Talos Services...\033[0m"

    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    local nodes_with_volumes="worker-1 worker-2 worker-3 worker-4 worker-5 worker-6 worker-7 worker-8"

    local unhealthy_services=""

    for node in $nodes_with_volumes; do
        local ip
        ip=$(yq -r ".nodes[] | select(.name == \"$node\") | .ip" "$nodes_yaml")

        if [ -z "$ip" ] || [ "$ip" == "null" ]; then
            echo -e "\033[33m  ⚠️  $node: IP inte hittad i nodes.yaml\033[0m"
            continue
        fi

        local ext_iscsid_state
        ext_iscsid_state=$(talosctl service ext-iscsid -n "$ip" 2>/dev/null | awk '/^STATE/ {print $2}')

        if [ -z "$ext_iscsid_state" ]; then
            ext_iscsid_state="NoResponse"
        fi

        if [ "$ext_iscsid_state" == "Running" ]; then
            echo -e "\033[32m  ✓ $node: ext-iscsid Running\033[0m"
        else
            echo -e "\033[31m  ✗ $node: ext-iscsid $ext_iscsid_state\033[0m"
            unhealthy_services="$unhealthy_services $node:ext-iscsid:$ext_iscsid_state"
        fi

        local services_output
        services_output=$(talosctl services -n "$ip" 2>/dev/null)

        if [ -z "$services_output" ]; then
            echo -e "\033[33m  ⚠️  $node: Kunde inte hämta tjänster\033[0m"
            continue
        fi

        local node_unhealthy
        node_unhealthy=$(echo "$services_output" | awk 'NR>1 && $4 != "OK" && $2 != "ext-iscsid" {print $2":"$4}')
        if [ -n "$node_unhealthy" ]; then
            while IFS=: read -r service health; do
                echo -e "\033[31m    ✗ $service: $health\033[0m"
                unhealthy_services="$unhealthy_services $node:$service:$health"
            done <<< "$node_unhealthy"
        fi
    done

    if [ -n "$unhealthy_services" ]; then
        echo -e "\033[33m  Services: $(echo $unhealthy_services | wc -w) tjänster med problem\033[0m"
    else
        echo -e "\033[32m  Alla tjänster OK\033[0m"
    fi
}

main_kubernetes_health() {
    echo "🔍 Kubernetes Health Check"
    echo "=========================="

    local required_commands=("ping" "talosctl" "kubectl" "yq")
    echo -e "\n\033[34m0. Kontrollerar required tools...\033[0m"
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            echo -e "\033[31m❌ $cmd not found\033[0m"
            return 1
        fi
        echo -e "\033[32m✓ $cmd\033[0m"
    done

    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    if [ ! -f "$nodes_yaml" ]; then
        echo -e "\033[31m❌ nodes.yaml not found: $nodes_yaml\033[0m"
        return 1
    fi

    local continue_after_argocd=1

    echo -e "\n\033[34m1. PING NODER...\033[0m"

    local controlplane_ips worker_ips
    controlplane_ips=$(yq -r '.nodes[] | select(.role == "controlplane") | .ip' "$nodes_yaml")
    worker_ips=$(yq -r '.nodes[] | select(.role == "worker") | .ip' "$nodes_yaml")

    echo -e "\033[33m  Controlplane nodes...\033[0m"
    while IFS= read -r ip; do
        if [ -n "$ip" ]; then
            if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                echo -e "\033[32m    ✓ $ip responds\033[0m"
            else
                echo -e "\033[31m    ✗ $ip FAILED\033[0m"
                echo -e "\033[31m❌ Controlplane node failed, aborting\033[0m"
                return 1
            fi
        fi
    done <<< "$controlplane_ips"

    echo -e "\033[33m  Worker nodes...\033[0m"
    local total_workers=0 failed_workers=0
    while IFS= read -r ip; do
        if [ -n "$ip" ]; then
            total_workers=$((total_workers + 1))
            if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                echo -e "\033[32m    ✓ $ip responds\033[0m"
            else
                echo -e "\033[31m    ✗ $ip FAILED\033[0m"
                failed_workers=$((failed_workers + 1))
            fi
        fi
    done <<< "$worker_ips"

    if [ "$total_workers" -gt 0 ]; then
        local failure_percentage=$((failed_workers * 100 / total_workers))
        if [ "$failure_percentage" -gt 26 ]; then
            echo -e "\033[31m❌ $failed_workers/$total_workers workers failed ($failure_percentage% > 26%), aborting\033[0m"
            return 1
        fi
    fi

    local talos_node="10.10.10.11"

    echo -e "\n\033[34m2. talosctl health...\033[0m"
    local talos_output
    talos_output=$(talosctl health --nodes "$talos_node" 2>&1)
    if [ $? -ne 0 ]; then
        echo -e "\033[31m❌ talosctl health failed\033[0m"
        echo "$talos_output"
        return 1
    fi
    local green=$'\033[32m'
    local reset=$'\033[0m'
    echo "$talos_output" | while IFS= read -r line; do
        if [[ "$line" == *": OK" ]] || [[ "$line" == *"..." ]]; then
            echo "${green}${line}${reset}"
        else
            echo "$line"
        fi
    done

    echo -e "\n\033[34m5. kubectl get nodes...\033[0m"
    kubectl get nodes | while IFS= read -r line; do
        if echo "$line" | grep -q "Ready"; then
            echo -e "\033[32m✓ $line\033[0m"
        else
            echo "$line"
        fi
    done

    echo -e "\n\033[34m6. ArgoCD pods...\033[0m"
    local green=$'\033[32m'
    local red=$'\033[31m'
    local reset=$'\033[0m'
    local has_error=0
    while IFS= read -r line; do
        if [[ "$line" == *"Running"* ]] || [[ "$line" == *"Completed"* ]]; then
            echo -e "${green}$line${reset}"
        else
            echo -e "${red}$line${reset}"
            has_error=1
        fi
    done < <(kubectl get pods -n argocd --no-headers 2>/dev/null)
    if [ $has_error -eq 1 ]; then
        echo -e "\n\033[31m❌ Det finns poddar som inte kör i argocd\033[0m"
        continue_after_argocd=0
    fi

    echo -e "\n\033[34m6.5. Pending CSR...\033[0m"
    local pending_csrs
    pending_csrs=$(kubectl get csr --no-headers 2>/dev/null | grep "Pending" | wc -l)

    if [ "$pending_csrs" -gt 0 ]; then
        echo -e "\033[31m❌ Det finns $pending_csrs pending CSR som behöver godkännas:\033[0m"
        kubectl get csr 2>/dev/null | grep "Pending"
        return 1
    else
        echo -e "\033[32m  ✓ Inga pending CSR\033[0m"
    fi

    echo -e "\n\033[34m7. Longhorn status...\033[0m"
    local green=$'\033[32m'
    local red=$'\033[31m'
    local yellow=$'\033[33m'
    local reset=$'\033[0m'

    local volumes
    volumes=$(kubectl get volumes -n longhorn-system --no-headers 2>/dev/null)
    local healthy degraded faulted unknown detached
    healthy=$(echo "$volumes" | grep -c "healthy" || echo 0)
    degraded=$(echo "$volumes" | grep -c "degraded" || echo 0)
    faulted=$(echo "$volumes" | grep -c "faulted" || echo 0)
    unknown=$(echo "$volumes" | grep -c "unknown" || echo 0)
    detached=$(echo "$volumes" | grep -c "detached" || echo 0)

    echo "Volumes:"
    echo -e "  ${green}Healthy: $healthy${reset}"
    echo -e "  ${yellow}Degraded: $degraded${reset}"
    echo -e "  ${red}Fault: $faulted${reset}"
    echo -e "  ${red}Unknown: $unknown${reset}"
    echo -e "  Detached: $detached"

    echo "Nodes:"
    local unschedulable_disks=0
    local schedulable_disks=0

    if ! kubectl get nodes.longhorn.io -n longhorn-system >/dev/null 2>&1; then
        echo -e "\n\033[31m❌ Kan inte hämta Longhorn-nodes\033[0m"
        return 1
    fi

    for node in $(kubectl get nodes.longhorn.io -n longhorn-system -o jsonpath='{.items[*].metadata.name}'); do
        local node_schedulable=0
        local node_total=0
        local disk_status
        disk_status=$(kubectl get nodes.longhorn.io "$node" -n longhorn-system -o jsonpath='{.status.diskStatus}' 2>/dev/null)
        if [ -n "$disk_status" ] && [ "$disk_status" != "null" ]; then
            for disk in $(echo "$disk_status" | jq -r 'keys[]'); do
                node_total=$((node_total + 1))
                local schedulable
                schedulable=$(echo "$disk_status" | jq -r ".[\"$disk\"].conditions[] | select(.type == \"Schedulable\") | .status")
                if [ "$schedulable" = "True" ]; then
                    node_schedulable=$((node_schedulable + 1))
                fi
            done
        fi
        if [ "$node_schedulable" -eq "$node_total" ] && [ "$node_total" -gt 0 ]; then
            echo -e "  ${green}$node: $node_schedulable/$node_total diskar schedulable${reset}"
            schedulable_disks=$((schedulable_disks + 1))
        else
            echo -e "  ${yellow}$node: $node_schedulable/$node_total diskar schedulable${reset}"
            unschedulable_disks=$((unschedulable_disks + 1))
        fi
    done

    if [ "$faulted" -gt 0 ] || [ "$unknown" -gt 0 ] || [ "$unschedulable_disks" -gt 0 ]; then
        echo -e "\n\033[31m❌ Det finns problem med Longhorn\033[0m"
        return 1
    fi

    echo -e "\n\033[34m8. Vault fullständig health...\033[0m"

    local green=$'\033[32m'
    local red=$'\033[31m'
    local yellow=$'\033[33m'
    local reset=$'\033[0m'

    echo -e "\n\033[33m  Poddar i vault namespace...\033[0m"
    local vault_pods_error=0
    while IFS= read -r line; do
        local ready_status
        ready_status=$(echo "$line" | awk '{print $2}')
        local ready running
        ready=$(echo "$ready_status" | cut -d'/' -f1)
        running=$(echo "$ready_status" | cut -d'/' -f2)
        
        if [[ "$line" == *"Running"* ]] && [ "$ready" -eq "$running" ] 2>/dev/null; then
            echo -e "  ${green}$line${reset}"
        else
            echo -e "  ${red}$line${reset}"
            vault_pods_error=1
        fi
    done < <(kubectl get pods -n vault --no-headers 2>/dev/null)

    if [ $vault_pods_error -eq 1 ]; then
        echo -e "\n\033[31m❌ Det finns problem med Vault-poddar\033[0m"
        return 1
    fi

    echo -e "\n\033[33m  Unsealed status...\033[0m"
    local vault_pod
    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$vault_pod" ]; then
        echo -e "\033[31m❌ No Vault pod found in namespace vault\033[0m"
        return 1
    fi
    local vault_status
    vault_status=$(kubectl exec -n vault "$vault_pod" -- vault status 2>/dev/null | grep "Seal Status" | awk '{print $3}')
    if [ "$vault_status" = "unsealed" ]; then
        echo -e "\033[32m  ✓ Vault is unsealed\033[0m"
    else
        echo -e "\033[31m❌ Vault is NOT unsealed (status: $vault_status)\033[0m"
        return 1
    fi

    echo -e "\n\033[33m  Health endpoint...\033[0m"
    local vault_health
    vault_health=$(kubectl exec -n vault "$vault_pod" -- vault read sys/health -format=json 2>/dev/null)
    if [ -n "$vault_health" ]; then
        local vault_initialized vault_sealed vault_standby
        vault_initialized=$(echo "$vault_health" | jq -r '.data.initialized' 2>/dev/null)
        vault_sealed=$(echo "$vault_health" | jq -r '.data.sealed' 2>/dev/null)
        vault_standby=$(echo "$vault_health" | jq -r '.data.standby' 2>/dev/null)
        echo -e "    Initialized: ${vault_initialized}"
        echo -e "    Sealed: ${vault_sealed}"
        echo -e "    Standby: ${vault_standby}"
    else
        echo -e "\033[31m❌ Kunde inte läsa Vault health\033[0m"
    fi

    echo -e "\n\033[33m  Test läsa secret...\033[0m"
    local secret_test
    secret_test=$(kubectl exec -n vault "$vault_pod" -- vault kv get secret/data/test 2>/dev/null)
    if [ -n "$secret_test" ]; then
        echo -e "\033[32m  ✓ Kan läsa secrets\033[0m"
    else
        echo -e "\033[33m  ⚠ Kan inte läsa test-secret (kan vara normalt)\033[0m"
    fi

    if [ "$continue_after_argocd" -eq 0 ]; then
        return 1
    fi

    echo -e "\n\033[34m9. Versioner...\033[0m"
    main_kubernetes_versions

    main_kubernetes_iscsi_health

    echo -e "\n\033[32m✅ Alla health checks klar!\033[0m"
    return 0
}

main_kubernetes_versions() {
    local green=$'\033[32m'
    local yellow=$'\033[33m'
    local red=$'\033[31m'
    local reset=$'\033[0m'

    echo -e "\n\033[34mKubernetes versioner...\033[0m"

    local kubectl_versions
    kubectl_versions=$(kubectl version -o json 2>&1)
    local kubectl_exit=$?

    if [ $kubectl_exit -ne 0 ]; then
        echo -e "${red}❌ Kunde inte hämta kubectl version: $kubectl_versions${reset}"
    else
        local client_version server_version
        client_version=$(echo "$kubectl_versions" | jq -r '.clientVersion.gitVersion' 2>/dev/null)
        server_version=$(echo "$kubectl_versions" | jq -r '.serverVersion.gitVersion' 2>/dev/null)

        local latest_k8s
        latest_k8s=$(curl -sSL "https://dl.k8s.io/release/stable-1.txt" 2>/dev/null | tr -d '\r')

        echo "  Client: $client_version"

        if [ "$server_version" = "null" ] || [ -z "$server_version" ]; then
            echo -e "  Server: ${red}Kunde inte hämta${reset}"
        else
            echo -n "  Server: $server_version"
            if [ -n "$latest_k8s" ]; then
                local normalized_server="${server_version#v}"
                local normalized_latest="${latest_k8s#v}"
                if [ "$normalized_server" = "$normalized_latest" ]; then
                    echo -e " ${green}✅ (senaste: $latest_k8s)${reset}"
                else
                    echo -e " ${yellow}⚠️  (senaste: $latest_k8s)${reset}"
                fi
            else
                echo ""
            fi
        fi
    fi

    echo -e "\n\033[34mTalos versioner...\033[0m"

    local talosctl_output
    talosctl_output=$(talosctl version --nodes 10.10.10.11 2>&1)
    local talos_exit=$?

    if [ $talos_exit -ne 0 ]; then
        echo -e "${red}❌ Kunde inte hämta talosctl version: $talosctl_output${reset}"
    else
        local talos_client_version talos_server_version
        talos_client_version=$(echo "$talosctl_output" | awk '/^Client:/{found=1} found && /Tag:/{print $2; exit}' | tr -d '\r')
        talos_server_version=$(echo "$talosctl_output" | awk '/^Server:/{found=1} found && /Tag:/{print $2; exit}' | tr -d '\r')

        local latest_talos
        latest_talos=$(curl -sSL "https://api.github.com/repos/siderolabs/talos/releases/latest" 2>/dev/null | jq -r '.tag_name' 2>/dev/null | sed 's/^v//')

        echo "  Client: $talos_client_version"

        if [ -z "$talos_server_version" ] || [ "$talos_server_version" = "null" ]; then
            echo -e "  Server: ${red}Kunde inte hämta${reset}"
        else
            echo -n "  Server: $talos_server_version"
            if [ -n "$latest_talos" ]; then
                local normalized_talos_server="${talos_server_version#v}"
                if [ "$normalized_talos_server" = "$latest_talos" ]; then
                    echo -e " ${green}✅ (senaste: $latest_talos)${reset}"
                else
                    echo -e " ${yellow}⚠️  (senaste: $latest_talos)${reset}"
                fi
            else
                echo ""
            fi
        fi
    fi
}
