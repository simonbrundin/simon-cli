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
    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    
    if [ -z "$selected_node" ]; then
        # Kör för alla noder
        local all_nodes
        all_nodes=$(kubectl get nodes -o json | jq -r '.items[] | select(.metadata.name | startswith("worker")) | .metadata.name')
        
        echo "=== Longhorn Disks för alla noder ==="
        echo ""
        
        for selected_node in $all_nodes; do
            # Hämta IP tidigt
            if [ ! -f "$nodes_yaml" ]; then
                echo -e "\033[31m❌ nodes.yaml not found: $nodes_yaml\033[0m"
                continue
            fi
            local ip
            ip=$(yq -r ".nodes[] | select(.name == \"$selected_node\") | .ip" "$nodes_yaml")
            if [ -z "$ip" ] || [ "$ip" = "null" ]; then
                echo -e "\033[31m❌ IP not found for node: $selected_node\033[0m"
                continue
            fi
            
            echo -e "\033[34m=== $selected_node ($ip) ===\033[0m"
            
            # === SCHEDULABLE STATUS ===
            echo -e "\033[34mSchedulable Status:\033[0m"

            local lhnodes_json
            lhnodes_json=$(kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null)

            if [ -n "$lhnodes_json" ] && echo "$lhnodes_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
                local schedulable ready
                schedulable=$(echo "$lhnodes_json" | jq -r ".items[] | select(.metadata.name == \"$selected_node\") | .status.conditions[] | select(.type == \"Schedulable\") | .status" 2>/dev/null)
                ready=$(echo "$lhnodes_json" | jq -r ".items[] | select(.metadata.name == \"$selected_node\") | .status.conditions[] | select(.type == \"Ready\") | .status" 2>/dev/null)

                if [ "$schedulable" = "True" ]; then
                    echo -e "  Schedulable: \033[32mYes\033[0m"
                else
                    echo -e "  Schedulable: \033[31mNo\033[0m"
                fi
                if [ "$ready" = "True" ]; then
                    echo -e "  Ready: \033[32mYes\033[0m"
                else
                    echo -e "  Ready: \033[31mNo\033[0m"
                fi
            fi

            # === LONGHORN DISKS ===
            echo -e "\033[34mLonghorn Disks:\033[0m"

            local lh_node_json
            lh_node_json=$(kubectl get nodes.longhorn.io "$selected_node" -n longhorn-system -o json 2>/dev/null)

            if [ -n "$lh_node_json" ] && echo "$lh_node_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
                local disk_status_json
                disk_status_json=$(echo "$lh_node_json" | jq -r '.status.diskStatus' 2>/dev/null)

                if [ -n "$disk_status_json" ] && echo "$disk_status_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
                    while IFS='|' read -r disk_id; do
                        [ -z "$disk_id" ] && continue

                        local conditions_json ready schedulable storage_avail storage_maximum disk_path disk_name filesystem_type
                        conditions_json=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".conditions // []" 2>/dev/null)
                        ready=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Ready") | .status' 2>/dev/null)
                        schedulable=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Schedulable") | .status' 2>/dev/null)
                        storage_avail=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".storageAvailable" 2>/dev/null)
                        storage_maximum=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".storageMaximum" 2>/dev/null)
                        disk_path=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskPath // \"\"" 2>/dev/null)
                        disk_name=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskName // \"\"" 2>/dev/null)
                        filesystem_type=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".filesystemType // \"\"" 2>/dev/null)

                        local phys_disk=""
                        local disk_exists=false
                        local ssd_num=""

                        if [ -n "$disk_path" ] && [ "$disk_path" != "null" ]; then
                            ssd_num=$(echo "$disk_path" | sed 's|/var/mnt/ssd-||' | grep -o '^[0-9]*' || true)
                        fi
                        if [ -z "$ssd_num" ]; then
                            ssd_num=$(echo "$disk_id" | sed 's/disk-//' | grep -o '^[0-9]*' || true)
                        fi

                        if [ "$ssd_num" = "1" ]; then
                            phys_disk="sda"
                            talosctl get dv -n "$ip" 2>/dev/null | grep -q "sda\s" && disk_exists=true
                        elif [ "$ssd_num" = "2" ]; then
                            phys_disk="sdb"
                            talosctl get dv -n "$ip" 2>/dev/null | grep -q "sdb\s" && disk_exists=true
                        elif [ "$ssd_num" = "3" ]; then
                            phys_disk="sdc"
                            talosctl get dv -n "$ip" 2>/dev/null | grep -q "sdc\s" && disk_exists=true
                        fi

                        local storage_str="" maximum_str=""
                        if [ -n "$storage_avail" ] && [ "$storage_avail" != "null" ] && [ "$storage_avail" -gt 0 ] 2>/dev/null; then
                            storage_str=$(echo "$storage_avail" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
                        fi
                        if [ -n "$storage_maximum" ] && [ "$storage_maximum" != "null" ] && [ "$storage_maximum" -gt 0 ] 2>/dev/null; then
                            maximum_str=$(echo "$storage_maximum" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
                        fi

                        local disk_label="$disk_name"
                        if [ -z "$disk_label" ] || [ "$disk_label" = "null" ] || [ "$disk_label" = "\"\"" ]; then
                            disk_label="$disk_id"
                        fi

                        if [ "$ready" = "True" ] && [ "$schedulable" = "True" ]; then
                            # Disken fungerar helt
                            echo -e "  \033[32m$disk_label\033[0m"
                            [ -n "$maximum_str" ] && echo "    Capacity: $maximum_str"
                            [ -n "$storage_str" ] && echo "    Available: $storage_str"
                            [ -n "$phys_disk" ] && echo "    Physical: /dev/$phys_disk"
                        elif [ "$ready" = "True" ] && [ "$schedulable" = "False" ]; then
                            # Disken fungerar men är full/på max
                            echo -e "  \033[33m$disk_label (full)\033[0m"
                            [ -n "$maximum_str" ] && echo "    Capacity: $maximum_str"
                            [ -n "$storage_str" ] && echo "    Available: $storage_str"
                            [ -n "$phys_disk" ] && echo "    Physical: /dev/$phys_disk"
                            
                            local reason
                            reason=$(echo "$conditions_json" | jq -r '.[] | select(.status == "False") | .message' 2>/dev/null | head -1)
                            if [ -n "$reason" ] && [ "$reason" != "null" ]; then
                                if echo "$reason" | grep -q "DiskPressure\|not schedulable"; then
                                    echo -e "    \033[31mOrsak: Disken är full\033[0m"
                                else
                                    echo "    Orsak: $reason"
                                fi
                            fi
                        else
                            # Disken fungerar inte
                            echo -e "  \033[31m$disk_label\033[0m"
                             
                            local reason
                            reason=$(echo "$conditions_json" | jq -r '.[] | select(.status == "False") | .message' 2>/dev/null | head -1)

                            if [ -n "$phys_disk" ]; then
                                if [ "$disk_exists" = true ]; then
                                    echo "    Physical: /dev/$phys_disk"
                                else
                                    echo "    Physical: /dev/$phys_disk (saknas)"
                                fi
                            fi

                            if [ "$disk_exists" = false ]; then
                                echo -e "    \033[31mOrsak: Disken är inte inkopplad\033[0m"
                            elif [ -n "$reason" ] && [ "$reason" != "null" ]; then
                                if echo "$reason" | grep -q "no such file or directory"; then
                                    echo -e "    \033[31mOrsak: Konfigurationsfil saknas\033[0m"
                                elif echo "$reason" | grep -q "DiskPressure"; then
                                    echo -e "    \033[31mOrsak: Disken är full\033[0m"
                                elif echo "$reason" | grep -q "NotReady\|NoDiskInfo"; then
                                    echo -e "    \033[31mOrsak: Disken är inte redo\033[0m"
                                else
                                    echo "    Orsak: $reason"
                                fi
                            fi
                        fi
                    done < <(echo "$disk_status_json" | jq -r 'to_entries[] | .key' 2>/dev/null)
                fi
            fi
            
            echo ""
        done
        return 0
    fi
    
    if [ -z "$selected_node" ]; then
        echo "Ingen node vald"
        return 1
    fi
    
    echo -e "\033[34mVald node: \033[0m$selected_node\n"

    # Hämta IP tidigt för att kunna använda i Longhorn Disks-sektionen
    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    if [ ! -f "$nodes_yaml" ]; then
        echo -e "\033[31m❌ nodes.yaml not found: $nodes_yaml\033[0m"
        return 1
    fi
    local ip
    ip=$(yq -r ".nodes[] | select(.name == \"$selected_node\") | .ip" "$nodes_yaml")
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        echo -e "\033[31m❌ IP not found for node: $selected_node\033[0m"
        return 1
    fi

    # === SCHEDULABLE STATUS ===
    echo -e "\033[34m=== Schedulable Status ===\033[0m"

    local lhnodes_json
    lhnodes_json=$(kubectl get nodes.longhorn.io -n longhorn-system -o json 2>/dev/null)

    if [ -n "$lhnodes_json" ] && echo "$lhnodes_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
        local schedulable ready
        schedulable=$(echo "$lhnodes_json" | jq -r ".items[] | select(.metadata.name == \"$selected_node\") | .status.conditions[] | select(.type == \"Schedulable\") | .status" 2>/dev/null)
        ready=$(echo "$lhnodes_json" | jq -r ".items[] | select(.metadata.name == \"$selected_node\") | .status.conditions[] | select(.type == \"Ready\") | .status" 2>/dev/null)

        if [ "$schedulable" = "True" ]; then
            echo -e "  Schedulable: \033[32mYes\033[0m"
        else
            echo -e "  Schedulable: \033[31mNo\033[0m"
        fi
        if [ "$ready" = "True" ]; then
            echo -e "  Ready: \033[32mYes\033[0m"
        else
            echo -e "  Ready: \033[31mNo\033[0m"
        fi
    fi

    # === LONGHORN DISKS ===
    echo -e "\n\033[34m=== Longhorn Disks ===\033[0m"

    local lh_node_json
    lh_node_json=$(kubectl get nodes.longhorn.io "$selected_node" -n longhorn-system -o json 2>/dev/null)

    if [ -n "$lh_node_json" ] && echo "$lh_node_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
        local disk_status_json
        disk_status_json=$(echo "$lh_node_json" | jq -r '.status.diskStatus' 2>/dev/null)

        local total_disks schedulable_count
        total_disks=$(echo "$disk_status_json" | jq 'keys | length' 2>/dev/null)
        schedulable_count=0
        local has_not_schedulable=false

        if [ -n "$disk_status_json" ] && echo "$disk_status_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
            while IFS='|' read -r disk_id; do
                [ -z "$disk_id" ] && continue

                local conditions_json ready schedulable storage_avail storage_maximum disk_path disk_name filesystem_type
                conditions_json=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".conditions // []" 2>/dev/null)
                ready=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Ready") | .status' 2>/dev/null)
                schedulable=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Schedulable") | .status' 2>/dev/null)
                storage_avail=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".storageAvailable" 2>/dev/null)
                storage_maximum=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".storageMaximum" 2>/dev/null)
                disk_path=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskPath // \"\"" 2>/dev/null)
                disk_name=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskName // \"\"" 2>/dev/null)
                filesystem_type=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".filesystemType // \"\"" 2>/dev/null)

                # Hitta motsvarande fysisk disk
                local phys_disk=""
                local disk_exists=false
                local ssd_num=""

                # Försök från disk_path först, sen från disk_id (tex disk-2 -> 2)
                if [ -n "$disk_path" ] && [ "$disk_path" != "null" ]; then
                    ssd_num=$(echo "$disk_path" | sed 's|/var/mnt/ssd-||' | grep -o '^[0-9]*' || true)
                fi
                if [ -z "$ssd_num" ]; then
                    ssd_num=$(echo "$disk_id" | sed 's/disk-//' | grep -o '^[0-9]*' || true)
                fi

                if [ "$ssd_num" = "1" ]; then
                    phys_disk="sda"
                    talosctl get dv -n "$ip" 2>/dev/null | grep -q "sda\s" && disk_exists=true
                elif [ "$ssd_num" = "2" ]; then
                    phys_disk="sdb"
                    talosctl get dv -n "$ip" 2>/dev/null | grep -q "sdb\s" && disk_exists=true
                elif [ "$ssd_num" = "3" ]; then
                    phys_disk="sdc"
                    talosctl get dv -n "$ip" 2>/dev/null | grep -q "sdc\s" && disk_exists=true
                fi

                # Formatera storage
                local storage_str="" maximum_str=""
                if [ -n "$storage_avail" ] && [ "$storage_avail" != "null" ] && [ "$storage_avail" -gt 0 ] 2>/dev/null; then
                    storage_str=$(echo "$storage_avail" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
                fi
                if [ -n "$storage_maximum" ] && [ "$storage_maximum" != "null" ] && [ "$storage_maximum" -gt 0 ] 2>/dev/null; then
                    maximum_str=$(echo "$storage_maximum" | awk '{printf "%.1f GB", $1/1024/1024/1024}')
                fi

                # Label
                local disk_label="$disk_name"
                if [ -z "$disk_label" ] || [ "$disk_label" = "null" ] || [ "$disk_label" = "\"\"" ]; then
                    disk_label="$disk_id"
                fi

                echo -n "  $disk_label: "

                if [ "$ready" = "True" ] && [ "$schedulable" = "True" ]; then
                    echo -e "\033[32mSchedulable\033[0m"
                    [ -n "$maximum_str" ] && echo "    Capacity: $maximum_str"
                    [ -n "$storage_str" ] && echo "    Available: $storage_str"
                    [ -n "$phys_disk" ] && echo "    Physical: /dev/$phys_disk"
                    [ -n "$filesystem_type" ] && [ "$filesystem_type" != "null" ] && echo "    Filesystem: $filesystem_type"
                    schedulable_count=$((schedulable_count + 1))
                else
                    echo -e "\033[31mNOT SCHEDULABLE\033[0m"
                    [ -n "$maximum_str" ] && echo "    Capacity: $maximum_str"
                    [ -n "$storage_str" ] && echo "    Available: $storage_str"
                    has_not_schedulable=true
                    
                    # Hämta orsak först för att avgöra vad som är fel
                    local reason
                    reason=$(echo "$conditions_json" | jq -r '.[] | select(.status == "False") | .message' 2>/dev/null | head -1)

                    if [ -n "$phys_disk" ]; then
                        if [ "$disk_exists" = true ]; then
                            echo "    Physical: /dev/$phys_disk"
                        else
                            echo "    Physical: /dev/$phys_disk (saknas - disk ej ansluten)"
                        fi
                    fi

                    if [ "$disk_exists" = false ]; then
                        # Disken är inte alls inkopplad
                        echo -e "    \033[31mOrsak: Disken är inte inkopplad\033[0m"
                    elif [ -n "$reason" ] && [ "$reason" != "null" ]; then
                        # Gör felmeddelandet mer läsbart på svenska
                        if echo "$reason" | grep -q "no such file or directory"; then
                            echo -e "    \033[31mOrsak: Konfigurationsfil saknas på disken\033[0m"
                        elif echo "$reason" | grep -q "DiskPressure"; then
                            echo -e "    \033[31mOrsak: Disken är full\033[0m"
                        elif echo "$reason" | grep -q "NotReady"; then
                            echo -e "    \033[31mOrsak: Disken är inte redo\033[0m"
                        elif echo "$reason" | grep -q "NoDiskInfo"; then
                            echo -e "    \033[31mOrsak: Ingen disk-information hittades\033[0m"
                        elif echo "$reason" | grep -q "space usage\|StorageAvailable\|less than"; then
                            echo -e "    \033[31mOrsak: Disken är full\033[0m"
                        elif echo "$reason" | grep -q "not schedulable"; then
                            echo -e "    \033[31mOrsak: Disken har inte plats\033[0m"
                        else
                            echo "    Orsak: $reason"
                        fi
                    fi
                fi
            done < <(echo "$disk_status_json" | jq -r 'to_entries[] | .key' 2>/dev/null)
        fi

        echo ""
        fi

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

    echo -e "\033[34mDiskar i Longhorn vs fysiskt inkopplade:\033[0m"
    local lh_node_json
    lh_node_json=$(kubectl get nodes.longhorn.io "$selected_node" -n longhorn-system -o json 2>/dev/null)

    local physical_disks_json
    physical_disks_json=$(talosctl get disks -n "$ip" -o json 2>/dev/null)

    local ssd_in_lh=""
    if [ -n "$lh_node_json" ] && echo "$lh_node_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
        local disk_status_json
        disk_status_json=$(echo "$lh_node_json" | jq -r '.status.diskStatus')
        if [ -n "$disk_status_json" ] && [ "$disk_status_json" != "null" ]; then
            while IFS='|' read -r lh_disk_id; do
                [ -z "$lh_disk_id" ] && continue
                local disk_path
                disk_path=$(echo "$disk_status_json" | jq -r ".\"$lh_disk_id\".diskPath // empty")
                if [ -n "$disk_path" ] && [ "$disk_path" != "null" ]; then
                    local ssd_num
                    ssd_num=$(echo "$disk_path" | sed 's|/var/mnt/ssd-||' | grep -o '^[0-9]*' || echo "")
                    local phys_disk=""
                    case "$ssd_num" in
                        1) phys_disk="/dev/sda" ;;
                        2) phys_disk="/dev/sdb" ;;
                        3) phys_disk="/dev/sdc" ;;
                    esac
                    local avail
                    avail=$(echo "$disk_status_json" | jq -r ".\"$lh_disk_id\".storageAvailable" 2>/dev/null)
                    local avail_str=""
                    if [ -n "$avail" ] && [ "$avail" != "null" ] && [ "$avail" -gt 0 ] 2>/dev/null; then
                        avail_str=" ($(echo "$avail" | awk '{printf "%.0f GB", $1/1024/1024/1024}') ledigt)"
                    fi
                    if [ -n "$phys_disk" ]; then
                        echo "  ssd-$ssd_num -> $lh_disk_id @ $phys_disk$avail_str (i Longhorn)"
                    else
                        echo "  ssd-$ssd_num -> $lh_disk_id$avail_str (i Longhorn)"
                    fi
                    if [ -n "$ssd_num" ]; then
                        ssd_in_lh="$ssd_in_lh $ssd_num "
                    fi
                fi
            done < <(echo "$disk_status_json" | jq -r 'to_entries[] | .key' 2>/dev/null)
        fi
    fi

    local patch_file="$HOME/repos/infrastructure/talos/patches/nodes/$selected_node.yaml"
    local configured_volumes
    configured_volumes=$(yq -r 'select(.kind == "UserVolumeConfig") | .name' "$patch_file" 2>/dev/null | tr '\n' ' ')

    if [ -n "$physical_disks_json" ] && [ "$physical_disks_json" != "null" ]; then
        while IFS= read -r disk_line; do
            [ -z "$disk_line" ] && continue
            local dev_path pretty_size bus_path disk_name
            dev_path=$(echo "$disk_line" | jq -r '.spec.dev_path')
            pretty_size=$(echo "$disk_line" | jq -r '.spec.pretty_size')
            bus_path=$(echo "$disk_line" | jq -r '.spec.bus_path // empty')
            disk_name=$(basename "$dev_path")

            if [ "$bus_path" = "/virtual" ]; then
                continue
            fi

            local ssd_num=""
            case "$disk_name" in
                sda) ssd_num="1" ;;
                sdb) ssd_num="2" ;;
                sdc) ssd_num="3" ;;
            esac

            if echo "$ssd_in_lh" | grep -q " $ssd_num "; then
                continue
            fi

            echo -e "  \033[33m$disk_name\033[0m"
            echo "    $pretty_size @ $dev_path"
            echo -e "    \033[31mEj tillagd i Longhorn\033[0m"
            if echo "$configured_volumes" | grep -qx "$disk_name"; then
                echo "    (konfigurerad i patch-fil men ej synlig i Longhorn)"
            else
                echo "    Lägg till med: simon kubernetes longhorn add disk"
            fi
        done < <(echo "$physical_disks_json" | jq -c 'select(.spec.bus_path != "/virtual" and .spec.transport == "usb")')
    fi

    if [ "$has_not_schedulable" = true ]; then
        return 1
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
    local mode="relaxed"
    if [ "$1" = "--strict" ]; then
        mode="strict"
    fi

    local health_errors=()

    handle_health_error() {
        local msg="$1"
        if [ "$mode" = "strict" ]; then
            echo -e "\033[31m❌ $msg\033[0m"
            return 1
        else
            echo -e "\033[31m⚠ $msg\033[0m"
            health_errors+=("$msg")
            return 0
        fi
    }

    echo "🔍 Kubernetes Health Check"
    echo "=========================="
    if [ "$mode" = "strict" ]; then
        echo "Mode: STRICT (abort on first error)"
    else
        echo "Mode: RELAXED (continue on errors, summarize at end)"
    fi
    echo ""

    local required_commands=("ping" "talosctl" "kubectl" "yq")
    echo -e "\033[34m0. Kontrollerar required tools...\033[0m"
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" >/dev/null 2>&1; then
            handle_health_error "$cmd not found"
        else
            echo -e "\033[32m✓ $cmd\033[0m"
        fi
    done

    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"
    if [ ! -f "$nodes_yaml" ]; then
        handle_health_error "nodes.yaml not found: $nodes_yaml"
    fi

    if [ ${#health_errors[@]} -gt 0 ] && [ "$mode" = "strict" ]; then
        return 1
    fi

    local continue_after_argocd=1

    echo -e "\n\033[34m1. PING NODER...\033[0m"

    local controlplane_ips worker_ips
    controlplane_ips=$(yq -r '.nodes[] | select(.role == "controlplane") | .ip' "$nodes_yaml")
    worker_ips=$(yq -r '.nodes[] | select(.role == "worker") | .ip' "$nodes_yaml")

    echo -e "\033[33m  Controlplane nodes...\033[0m"
    local controlplane_failed=0
    while IFS= read -r ip; do
        if [ -n "$ip" ]; then
            if ping -c 1 -W 2 "$ip" >/dev/null 2>&1; then
                echo -e "\033[32m    ✓ $ip responds\033[0m"
            else
                echo -e "\033[31m    ✗ $ip FAILED\033[0m"
                handle_health_error "Controlplane node $ip failed ping"
                controlplane_failed=1
            fi
        fi
    done <<< "$controlplane_ips"

    if [ $controlplane_failed -eq 1 ] && [ "$mode" = "strict" ]; then
        return 1
    fi

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
            handle_health_error "$failed_workers/$total_workers workers failed ($failure_percentage% > 26%)"
        fi
    fi

    local talos_node="10.10.10.11"

    echo -e "\n\033[34m2. talosctl health...\033[0m"
    local talos_output
    talos_output=$(talosctl health --nodes "$talos_node" 2>&1)
    if [ $? -ne 0 ]; then
        handle_health_error "talosctl health failed"
        echo "$talos_output"
    else
        local green=$'\033[32m'
        local reset=$'\033[0m'
        echo "$talos_output" | while IFS= read -r line; do
            if [[ "$line" == *": OK" ]] || [[ "$line" == *"..." ]]; then
                echo "${green}${line}${reset}"
            else
                echo "$line"
            fi
        done
    fi

    if [ ${#health_errors[@]} -gt 0 ] && [ "$mode" = "strict" ]; then
        return 1
    fi

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
        handle_health_error "Det finns poddar som inte kör i argocd"
        continue_after_argocd=0
    fi

    echo -e "\n\033[34m6.5. Pending CSR...\033[0m"
    local pending_csrs
    pending_csrs=$(kubectl get csr --no-headers 2>/dev/null | grep "Pending" | wc -l)

    if [ "$pending_csrs" -gt 0 ]; then
        handle_health_error "Det finns $pending_csrs pending CSR som behöver godkännas"
        kubectl get csr 2>/dev/null | grep "Pending"
    else
        echo -e "\033[32m  ✓ Inga pending CSR\033[0m"
    fi

    if [ ${#health_errors[@]} -gt 0 ] && [ "$mode" = "strict" ]; then
        return 1
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
        handle_health_error "Kan inte hämta Longhorn-nodes"
    else
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
    fi

    if [ "$faulted" -gt 0 ] || [ "$unknown" -gt 0 ] || [ "$unschedulable_disks" -gt 0 ]; then
        handle_health_error "Det finns problem med Longhorn (faulted=$faulted, unknown=$unknown, unschedulable=$unschedulable_disks)"
    fi

    if [ ${#health_errors[@]} -gt 0 ] && [ "$mode" = "strict" ]; then
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
        handle_health_error "Det finns problem med Vault-poddar"
    fi

    echo -e "\n\033[33m  Unsealed status...\033[0m"
    local vault_pod
    vault_pod=$(kubectl get pods -n vault -l app.kubernetes.io/name=vault -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [ -z "$vault_pod" ]; then
        handle_health_error "No Vault pod found in namespace vault"
    else
        local vault_status
        vault_status=$(kubectl exec -n vault "$vault_pod" -- vault status 2>/dev/null | grep "Seal Status" | awk '{print $3}')
        if [ "$vault_status" = "unsealed" ]; then
            echo -e "\033[32m  ✓ Vault is unsealed\033[0m"
        else
            handle_health_error "Vault is NOT unsealed (status: $vault_status)"
        fi
    fi

    echo -e "\n\033[33m  Health endpoint...\033[0m"
    if [ -n "$vault_pod" ]; then
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
            handle_health_error "Kunde inte läsa Vault health"
        fi
    fi

    echo -e "\n\033[33m  Test läsa secret...\033[0m"
    if [ -n "$vault_pod" ]; then
        local secret_test
        secret_test=$(kubectl exec -n vault "$vault_pod" -- vault kv get secret/data/test 2>/dev/null)
        if [ -n "$secret_test" ]; then
            echo -e "\033[32m  ✓ Kan läsa secrets\033[0m"
        else
            handle_health_error "Kan inte läsa test-secret"
        fi
    fi

    if [ ${#health_errors[@]} -gt 0 ] && [ "$mode" = "strict" ]; then
        return 1
    fi

    if [ "$continue_after_argocd" -eq 0 ]; then
        handle_health_error "ArgoCD has failing pods"
    fi

    echo -e "\n\033[34m9. Versioner...\033[0m"
    main_kubernetes_versions

    main_kubernetes_iscsi_health

    if [ ${#health_errors[@]} -gt 0 ]; then
        echo -e "\n\033[31m❌ Health check failures: ${#health_errors[@]}\033[0m"
        for err in "${health_errors[@]}"; do
            echo -e "  \033[31m• $err\033[0m"
        done
        return 1
    fi

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

main_kubernetes_longhorn_add_disk() {
    local selected_node="$1"
    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"

    if [ -z "$selected_node" ]; then
        echo -e "\033[34mVälj nod:\033[0m"
        kubectl get nodes -o json | jq -r '.items[] | select(.metadata.name | startswith("worker")) | .metadata.name' | while read -r node; do
            echo "  - $node"
        done
        echo ""
        echo -n "Ange nodnamn: "
        read -r selected_node
    fi

    if [ -z "$selected_node" ]; then
        echo -e "\033[31m❌ inget nodnamn angivet\033[0m"
        return 1
    fi

    local ip
    ip=$(yq -r ".nodes[] | select(.name == \"$selected_node\") | .ip" "$nodes_yaml")
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        echo -e "\033[31m❌ IP not found for node: $selected_node\033[0m"
        return 1
    fi

    local patch_file="$HOME/repos/infrastructure/talos/patches/nodes/$selected_node.yaml"
    if [ ! -f "$patch_file" ]; then
        echo -e "\033[31m❌ patch-fil hittades inte: $patch_file\033[0m"
        return 1
    fi

    echo -e "\033[34m=== Lägger till disk i Longhorn på $selected_node ===\033[0m\n"

    local disks_json
    disks_json=$(talosctl get disks -n "$ip" -o json 2>/dev/null)
    if [ -z "$disks_json" ] || [ "$disks_json" = "null" ]; then
        echo -e "\033[31m❌ kunde inte hämta diskar från $ip\033[0m"
        return 1
    fi

    local configured_volumes
    configured_volumes=$(yq -r 'select(.kind == "UserVolumeConfig") | .name' "$patch_file" 2>/dev/null | tr '\n' ' ')

    local configured_matchers=""
    while IFS= read -r matcher; do
        [ -z "$matcher" ] && continue
        configured_matchers="$configured_matchers|$matcher"
    done < <(yq -r 'select(.kind == "UserVolumeConfig") | .provisioning.diskSelector.match' "$patch_file" 2>/dev/null)
    configured_matchers="${configured_matchers#\|}"

    local available_disks_json="[]"
    while IFS= read -r disk_line; do
        [ -z "$disk_line" ] && continue
        local dev_path size pretty_size bus_path by_id
        dev_path=$(echo "$disk_line" | jq -r '.spec.dev_path')
        size=$(echo "$disk_line" | jq -r '.spec.size')
        pretty_size=$(echo "$disk_line" | jq -r '.spec.pretty_size')
        bus_path=$(echo "$disk_line" | jq -r '.spec.bus_path // empty')

        local disk_name
        disk_name=$(basename "$dev_path")

        if echo "$configured_volumes" | grep -qx "$disk_name"; then
            continue
        fi

        if [ "$bus_path" = "/virtual" ]; then
            continue
        fi

        by_id=$(echo "$disk_line" | jq -r '.spec.symlinks[]' 2>/dev/null | grep by-id | head -1 | sed 's|.*by-id/||')
        if [ -n "$by_id" ] && [ "$by_id" != "null" ] && [ "$by_id" != "" ]; then
            local skip=false
            if [ -n "$configured_matchers" ]; then
                local lh_node_json
                lh_node_json=$(kubectl get nodes.longhorn.io "$selected_node" -n longhorn-system -o json 2>/dev/null)
                for matcher in $configured_matchers; do
                    local target_id
                    target_id=$(echo "$matcher" | sed "s|.*by-id/||;s|'.*||")
                    if [ -n "$target_id" ] && [ "$target_id" != "in" ] && [ "$target_id" != "disk.symlinks" ]; then
                        if echo "$disk_line" | jq -r '.spec.symlinks[]' 2>/dev/null | grep -q "by-id/$target_id"; then
                            local ssd_num=""
                            case "$disk_name" in
                                sda) ssd_num="1" ;;
                                sdb) ssd_num="2" ;;
                                sdc) ssd_num="3" ;;
                            esac
                            local disk_in_lh=false
                            if [ -n "$ssd_num" ] && [ -n "$lh_node_json" ] && echo "$lh_node_json" | jq -s 'length > 0' 2>/dev/null | grep -q "true"; then
                                local disk_status_json
                                disk_status_json=$(echo "$lh_node_json" | jq -r '.status.diskStatus')
                                if [ -n "$disk_status_json" ] && [ "$disk_status_json" != "null" ]; then
                                    while IFS='|' read -r lh_disk_id; do
                                        [ -z "$lh_disk_id" ] && continue
                                        local lh_disk_path
                                        lh_disk_path=$(echo "$disk_status_json" | jq -r ".\"$lh_disk_id\".diskPath // empty")
                                        if [ -n "$lh_disk_path" ] && [ "$lh_disk_path" != "null" ]; then
                                            local lh_ssd_num
                                            lh_ssd_num=$(echo "$lh_disk_path" | sed 's|/var/mnt/ssd-||' | grep -o '^[0-9]*' || echo "")
                                            if [ "$ssd_num" = "$lh_ssd_num" ]; then
                                                disk_in_lh=true
                                                break
                                            fi
                                        fi
                                    done < <(echo "$disk_status_json" | jq -r 'to_entries[] | .key' 2>/dev/null)
                                fi
                            fi
                            if [ "$disk_in_lh" = true ]; then
                                skip=true
                                break
                            fi
                        fi
                    fi
                done
            fi
            if [ "$skip" = "false" ]; then
                available_disks_json=$(echo "$available_disks_json" | jq --arg dp "$dev_path" --arg sz "$size" --arg ps "$pretty_size" --arg bi "$by_id" --arg dn "$disk_name" '. += [{"dev_path": $dp, "size": $sz, "pretty_size": $ps, "by_id": $bi, "disk_name": $dn}]')
            fi
        fi
    done < <(echo "$disks_json" | jq -c 'select(.spec.bus_path != "/virtual")')

    local disk_count
    disk_count=$(echo "$available_disks_json" | jq 'length')
    if [ "$disk_count" = "0" ]; then
        echo -e "\033[33mInga tillgängliga diskar hittades på $selected_node\033[0m"
        echo "Alla diskar är redan konfigurerade."
        return 0
    fi

    if [ "$disk_count" -gt 1 ]; then
        echo -e "\033[34m=== Tillgängliga diskar på $selected_node ===\033[0m\n"
        echo "$available_disks_json" | jq -r '.[] | "  \(.disk_name) (\(.pretty_size))\n    by-id: \(.by_id)\n    dev_path: \(.dev_path)\n"' | head -50
        echo ""
        echo -n "Ange dev_path för disken du vill lägga till: "
        read -r chosen_path
    else
        chosen_path=$(echo "$available_disks_json" | jq -r '.[0].dev_path')
    fi

    local chosen_disk
    chosen_disk=$(echo "$available_disks_json" | jq --arg dp "$chosen_path" '.[] | select(.dev_path == $dp)')
    if [ -z "$chosen_disk" ] || [ "$chosen_disk" = "null" ]; then
        echo -e "\033[31m❌ okänd disk: $chosen_path\033[0m"
        return 1
    fi

    local by_id dev_path pretty_size
    by_id=$(echo "$chosen_disk" | jq -r '.by_id')
    dev_path=$(echo "$chosen_disk" | jq -r '.dev_path')
    pretty_size=$(echo "$chosen_disk" | jq -r '.pretty_size')

    local existing_ssd_names
    existing_ssd_names=$(echo "$configured_volumes" | tr ' ' '\n' | grep '^ssd-' | sed 's/ssd-//' | sort -n)
    local next_num=1
    if [ -n "$existing_ssd_names" ]; then
        next_num=$(echo "$existing_ssd_names" | tail -1 | awk '{print $1 + 1}')
    fi
    local new_volume_name="ssd-$next_num"

    echo ""
    echo -e "\033[34mDisk som kommer läggas till:\033[0m"
    echo "  Dev path:   $dev_path"
    echo "  Storlek:    $pretty_size"
    echo "  By-id:      $by_id"
    echo "  Namn:       $new_volume_name"

    local fs_type
    fs_type=$(talosctl get disks -n "$ip" -o json 2>/dev/null | jq --arg dp "$dev_path" '.items[] | select(.spec.dev_path == $dp) | .spec.filesystem // empty' 2>/dev/null | tr -d '"')
    if [ -z "$fs_type" ] || [ "$fs_type" = "null" ] || [ "$fs_type" = "gpt" ]; then
        echo ""
        echo -e "\033[33m⚠️  VARNING: Disken verkar inte ha XFS-format!\033[0m"
        echo "  Disken har antingen ingen filesystem eller GPT-partitionstabell."
        echo "  För att använda den i Longhorn behöver du först formatera den:"
        echo ""
        echo "    sudo mkfs.xfs -f $dev_path"
        echo ""
        echo -e "\033[31m❌ UPPLYSNING: Du måste formatera disken INNAN du lägger till den i Longhorn.\033[0m"
        echo "  Annars kommer Talos att misslyckas med: 'filesystem type mismatch: gpt != xfs'"
        echo ""
        echo -n "Vill du lägga till disken ändå och formatera den senare? [j/n]: "
        read -r confirm
        if [ "$confirm" != "j" ] && [ "$confirm" != "J" ]; then
            echo "Avbrutet."
            return 0
        fi
    fi

    echo ""
    echo -n "Vill du lägga till denna disk i Longhorn? [j/n]: "
    read -r confirm
    if [ "$confirm" != "j" ] && [ "$confirm" != "J" ]; then
        echo "Avbrutet."
        return 0
    fi

    local new_volume_config="---
apiVersion: v1alpha1
kind: UserVolumeConfig
name: $new_volume_name
volumeType: disk
provisioning:
  diskSelector:
    match: \"'/dev/disk/by-id/$by_id' in disk.symlinks\""

    if grep -q "^---$" "$patch_file"; then
        printf '\n%s\n' "$new_volume_config" >> "$patch_file"
    else
        printf '%s\n' "$new_volume_config" >> "$patch_file"
    fi

    echo ""
    echo -e "\033[32m✓ $new_volume_name har lagts till i patch-filen.\033[0m"

    echo ""
    echo -e "\033[34mLägger till disk i Longhorn via API...\033[0m"

    local disk_num
    disk_num=$(echo "$new_volume_name" | sed 's/ssd-//')

    local ssd_path="/var/mnt/$new_volume_name"
    local phys_disk=""
    case "$dev_path" in
        */sda) phys_disk="sda" ;;
        */sdb) phys_disk="sdb" ;;
        */sdc) phys_disk="sdc" ;;
        *) echo "  ⚠️ Kan inte avgöra fysisk disk för $dev_path"
    esac

    if [ -n "$phys_disk" ]; then
        local disk_uuid
        disk_uuid=$(blkid -s UUID -o value "$dev_path" 2>/dev/null || echo "")

        local lh_disk_name="disk-$disk_num"
        if [ "$disk_num" = "1" ]; then
            lh_disk_name="default-disk-b30600000000"
        fi
        if [ "$disk_num" -gt 1 ]; then
            lh_disk_name="disk-$((disk_num + 1))"
        fi

        echo "  Disk-nummer: $disk_num"
        echo "  Longhorn disk: $lh_disk_name"
        echo "  Sökväg: $ssd_path"
        echo "  Fysisk: /dev/$phys_disk"
        echo "  UUID: $disk_uuid"

        kubectl patch nodes.longhorn.io "$selected_node" -n longhorn-system --type='json' \
            -p "[{\"op\":\"add\",\"path\":\"/spec/disks/$lh_disk_name\",\"value\":{\"allowScheduling\":true,\"diskDriver\":\"\",\"diskType\":\"filesystem\",\"evictionRequested\":false,\"path\":\"$ssd_path\",\"storageReserved\":0,\"tags\":[]}}]" 2>/dev/null

        echo "  ✓ Longhorn spec uppdaterad"

        sleep 2

        local im_pod
        im_pod=$(kubectl get pods -n longhorn-system -o json | jq -r ".items[] | select(.metadata.name | contains(\"instance-manager\")) | select(.spec.nodeName == \"$selected_node\") | .metadata.name" 2>/dev/null | head -1)

        if [ -n "$im_pod" ] && [ -n "$disk_uuid" ]; then
            kubectl exec -n longhorn-system "$im_pod" -- sh -c "echo '{\"diskName\":\"$lh_disk_name\",\"diskUUID\":\"$disk_uuid\",\"diskDriver\":\"\"}' > /host$ssd_path/longhorn-disk.cfg" 2>/dev/null
            echo "  ✓ longhorn-disk.cfg skriven till /host$ssd_path/"
        elif [ -n "$im_pod" ]; then
            echo "  ⚠️ Kunde inte hämta UUID för longhorn-disk.cfg"
        fi
    fi

    echo ""
    echo "För att tillämpa ändringen, kör:"
    echo "  simon talos update config $selected_node"
}

main_kubernetes_longhorn_repair() {
    local selected_node="$1"
    local nodes_yaml="$HOME/repos/infrastructure/talos/nodes.yaml"

    if [ -z "$selected_node" ]; then
        echo -e "\033[34mTillgängliga noder med Longhorn-problem:\033[0m"
        kubectl get nodes.longhorn.io -n longhorn-system -o json | jq -r '.items[] | select(.status.conditions[] | select(.type == "Ready" and .status == "False")) | .metadata.name' | while read -r node; do
            local lh_node
            lh_node=$(kubectl get nodes.longhorn.io "$node" -n longhorn-system -o json 2>/dev/null)
            local disk_id reason
            disk_id=$(echo "$lh_node" | jq -r '.status.diskStatus | to_entries[0].key')
            reason=$(echo "$lh_node" | jq -r '.status.diskStatus | to_entries[0].value.conditions[] | select(.status == "False") | .message' | head -1)
            echo "  - $node"
            echo "    Disk: $disk_id"
            if echo "$reason" | grep -q "diskUUID"; then
                echo -e "    \033[31mProblem: diskUUID mismatch\033[0m"
            else
                echo "    Orsak: $reason"
            fi
        done
        echo ""
        echo -n "Ange nodnamn att reparera: "
        read -r selected_node
    fi

    if [ -z "$selected_node" ]; then
        echo -e "\033[31m❌ inget nodnamn angivet\033[0m"
        return 1
    fi

    local ip
    ip=$(yq -r ".nodes[] | select(.name == \"$selected_node\") | .ip" "$nodes_yaml" 2>/dev/null)
    if [ -z "$ip" ] || [ "$ip" = "null" ]; then
        echo -e "\033[31m❌ IP not found for node: $selected_node\033[0m"
        return 1
    fi

    echo -e "\033[34m=== Reparera Longhorn disk på $selected_node ($ip) ===\033[0m\n"

    local lh_node_json
    lh_node_json=$(kubectl get nodes.longhorn.io "$selected_node" -n longhorn-system -o json 2>/dev/null)

    if [ -z "$lh_node_json" ] || echo "$lh_node_json" | jq -s 'length == 0' 2>/dev/null | grep -q "true"; then
        echo -e "\033[31m❌ Longhorn-node hittades inte: $selected_node\033[0m"
        return 1
    fi

    local disk_status_json
    disk_status_json=$(echo "$lh_node_json" | jq -r '.status.diskStatus')

    if [ -z "$disk_status_json" ] || [ "$disk_status_json" = "null" ]; then
        echo -e "\033[31m❌ Inga diskar hittades på $selected_node\033[0m"
        return 1
    fi

    local disk_id disk_uuid disk_path
    disk_id=$(echo "$disk_status_json" | jq -r 'to_entries[0].key')
    disk_uuid=$(echo "$disk_status_json" | jq -r 'to_entries[0].value.diskUUID')
    disk_path=$(echo "$disk_status_json" | jq -r 'to_entries[0].value.diskPath')

    if [ -z "$disk_id" ] || [ "$disk_id" = "null" ]; then
        echo -e "\033[31m❌ Kunde inte hämta disk-information\033[0m"
        return 1
    fi

    local disk_name
    disk_name=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskName // \"$disk_id\"")

    local disk_driver
    disk_driver=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".diskDriver // \"\"")

    local expected_uuid="$disk_uuid"
    local disk_config_json="{\"diskName\":\"$disk_name\",\"diskUUID\":\"$expected_uuid\",\"diskDriver\":\"$disk_driver\"}"

    echo "Hittade disk:"
    echo "  Disk ID:   $disk_id"
    echo "  diskUUID:  $disk_uuid"
    echo "  Sökväg:    $disk_path"
    echo "  Disk config: $disk_config_json"
    echo ""

    local conditions_json ready_status schedulable_status
    conditions_json=$(echo "$disk_status_json" | jq -r ".\"$disk_id\".conditions // []")
    ready_status=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Ready") | .status')
    schedulable_status=$(echo "$conditions_json" | jq -r '.[] | select(.type == "Schedulable") | .status')
    local reason
    reason=$(echo "$conditions_json" | jq -r '.[] | select(.status == "False") | .message' | head -1)

    if [ "$ready_status" != "False" ] && [ "$schedulable_status" != "False" ]; then
        echo -e "\033[32m✓ Disken fungerar redan, inget att reparera\033[0m"
        return 0
    fi

    if ! echo "$reason" | grep -q "diskUUID"; then
        echo -e "\033[33m⚠️  Varning: Detta script reparerar endast diskUUID-mismatch\033[0m"
        echo "  Aktuellt problem: $reason"
        echo ""
        echo -n "Fortsätt ändå? [j/n]: "
        read -r confirm
        if [ "$confirm" != "j" ] && [ "$confirm" != "J" ]; then
            echo "Avbrutet."
            return 0
        fi
    fi

    echo -e "\033[34mSteg 1: Hämta UUID från Longhorn-node\033[0m"
    echo "  Förväntad UUID: $expected_uuid"

    echo -e "\033[34mSteg 2: Hämta fysisk disk\033[0m"
    local ssd_num
    ssd_num=$(echo "$disk_path" | sed 's|/var/mnt/ssd-||' | grep -o '^[0-9]*' || true)
    if [ -z "$ssd_num" ]; then
        ssd_num=$(echo "$disk_id" | sed 's/disk-//' | grep -o '^[0-9]*' || true)
    fi

    local phys_disk=""
    if [ "$ssd_num" = "1" ]; then
        phys_disk="sda"
    elif [ "$ssd_num" = "2" ]; then
        phys_disk="sdb"
    elif [ "$ssd_num" = "3" ]; then
        phys_disk="sdc"
    fi

    if [ -z "$phys_disk" ]; then
        echo -e "\033[31m❌ Kunde inte avgöra fysisk disk från sökväg/disk-id\033[0m"
        return 1
    fi

    echo "  Fysisk disk: /dev/$phys_disk"

    echo -e "\033[34mSteg 3: Kontrollera att disken finns\033[0m"
    local disk_exists=false
    if talosctl get dv -n "$ip" 2>/dev/null | grep -q "$phys_disk\s"; then
        disk_exists=true
    fi

    if [ "$disk_exists" = false ]; then
        echo -e "\033[31m❌ Disken /dev/$phys_disk finns inte på noden\033[0m"
        return 1
    fi

    echo -e "\033[34mSteg 4: Skriv longhorn-disk.cfg till disken (JSON-format)\033[0m"
    echo "  Kommando: echo '$disk_config_json' > $disk_path/longhorn-disk.cfg"

    local im_pod
    im_pod=$(kubectl get pods -n longhorn-system -o json | jq -r ".items[] | select(.metadata.name | contains(\"instance-manager\")) | select(.spec.nodeName == \"$selected_node\") | .metadata.name" 2>/dev/null | head -1)

    if [ -z "$im_pod" ]; then
        echo -e "\033[31m❌ Kunde inte hitta instance-manager pod för $selected_node\033[0m"
        return 1
    fi

    kubectl exec -n longhorn-system "$im_pod" -- sh -c "echo '$disk_config_json' > /host$disk_path/longhorn-disk.cfg" 2>&1
    local exec_result=$?

    if [ $exec_result -ne 0 ]; then
        echo -e "\033[31m❌ Kunde inte skriva till disken\033[0m"
        echo "  Försökte: echo '$disk_config_json' > '/host$disk_path/longhorn-disk.cfg'"
        return 1
    fi

    echo -e "\033[32m✓ Skrev till $im_pod\033[0m"

    echo -e "\033[34mSteg 5: Verifiera skrivning\033[0m"
    local written_content
    written_content=$(kubectl exec -n longhorn-system "$im_pod" -- cat "/host$disk_path/longhorn-disk.cfg" 2>/dev/null)

    if echo "$written_content" | jq -e '.diskUUID' >/dev/null 2>&1; then
        local verified_uuid
        verified_uuid=$(echo "$written_content" | jq -r '.diskUUID')
        if [ "$verified_uuid" != "$expected_uuid" ]; then
            echo -e "\033[31m❌ Verifiering misslyckades!\033[0m"
            echo "  Förväntad UUID: $expected_uuid"
            echo "  Skriven UUID:   $verified_uuid"
            return 1
        fi
    else
        echo -e "\033[31m❌ Verifiering misslyckades - inte giltigt JSON\033[0m"
        echo "  Skriven innehåll: $written_content"
        return 1
    fi

    echo -e "\033[32m✓ longhorn-disk.cfg skriven korrekt\033[0m"

    echo ""
    echo -e "\033[34mSteg 6: Vänta på Longhorn att upptäcka ändringen\033[0m"
    echo "  Longhorn kontrollerar disk-UUID regelbundet. Detta kan ta upp till 2 minuter."
    echo ""
    echo "  För att verifiera, kör:"
    echo "    simon kubernetes longhorn test $selected_node"
    echo ""
    echo -e "\033[32m✓ Reparation slutförd\033[0m"
    echo ""
    echo "  OBS: Om Longhorn fortfarande rapporterar mismatch efter några minuter,"
    echo "  kan du behöva starta about Longhorn-manager poddar på noden:"
    echo "    kubectl delete pod -n longhorn-system -l app=longhorn-manager --field-selector spec.nodeName=$selected_node"
}
