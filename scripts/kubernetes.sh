#!/bin/bash

# Converted from kubernetes.nu

main_k() {
    # simon.sh kubernetes "$@"
    echo "Kubernetes alias"
}

main_kubernetes_login_certificate() {
    clustername="${1:-}"

    echo -e "\033[34m🔐 Loggar in i 1Password...\033[0m"
    eval $(op account add --signin 2>/dev/null)

    if ! op whoami &>/dev/null; then
        echo -e "\033[31m[ERROR]\033[0m Kunde inte logga in i 1Password."
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

    components=""
    for type in $resource_types; do
        items=$(kubectl get "$type" -n "$selected_namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        for item in $items; do
            components="$components $type/$item"
        done
    done

    selected_components=$(fzfSelect "$components")

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

    components=""
    for type in $resource_types; do
        items=$(kubectl get "$type" -n "$selected_namespace" -o json 2>/dev/null | jq -r '.items[].metadata.name' 2>/dev/null)
        for item in $items; do
            components="$components $type/$item"
        done
    done

    selected_components=$(fzfSelect "$components")

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
    nodes=$(kubectl get nodes -o json | jq -r '.items[].metadata.name')
    selected_node=$(fzfSelect "$nodes")
    echo -e "\033[34mVald node: \033[0m$selected_node\n"

    echo -e "\033[34mInstallationsdisk:\033[0m"
    install_disk=$(talosctl get machineconfig -n "$selected_node" -o yaml | yq '.spec.machine.install.disk')
    if [ "$install_disk" = "/dev/mmcblk1" ]; then
        echo -e "\033[32m$install_disk\033[0m"
    else
        echo -e "\033[31m$install_disk\033[0m"
    fi

    echo -e "\033[34mInstallerade tillägg:\033[0m"
    extensions=$(talosctl get extensions -n "$selected_node" | awk 'NR>1 {print $1}')
    echo "$extensions"

    echo -e "\033[34mDiskar och deras filsystem:\033[0m"
    disks=$(talosctl get dv -n "$selected_node" | awk 'NR>1 && $1 ~ /^sd/ {print $1, $2}')
    echo "$disks"

    echo -e "\033[34mMachineconfig disks:\033[0m"
    machine_disks=$(talosctl get machineconfig -n "$selected_node" -o yaml | yq '.spec.machine.disks')
    echo "$machine_disks"
}

main_kubernetes_install_argocd() {
    kubectl create namespace argocd
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
}