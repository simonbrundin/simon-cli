#!/usr/bin/env nu

# Kort: Kubernetes
def "main k" [...args] { simon kubernetes ...$args }

def "main kubernetes login teleport" [clustername = ""] {
  # kommandon direkt från teleport
  bash -c "tsh login --proxy=teleport.simonbrundin.com:443 --auth=local --user=admin teleport.simonbrundin.com"
  # tsh login --proxy=teleport.simonbrundin.com:443 --auth=local --user=admin teleport.simonbrundin.com
  print $"(ansi blue)tsh login lyckades!(ansi reset)"
  bash -c "export kubeconfig=${HOME?}/teleport-kubeconfig.yaml"
  print $"(ansi blue)export kubeconfig lyckades!(ansi reset)"
  # $env.kubeconfig = $"($env.home)/teleport-kubeconfig.yaml"
  bash -c "unset TELEPORT_PROXY"
  bash -c "unset TELEPORT_CLUSTER"
  bash -c "unset TELEPORT_KUBE_CLUSTER"
  bash -c "unset KUBECONFIG"
  print "här"

  ["teleport_proxy", "teleport_cluster", "teleport_kube_cluster", "kubeconfig"]
  | each { |var|
    if ($var in $env) {
      hide-env $var
    }
  }
  $env.KUBECONFIG = ""
  bash -c "tsh kube login cluster1"
  print $"(ansi blue)tsh kube login lyckades!(ansi reset)"

  # Avsluta allt på port 8443 och vänta tills porten är ledig
  print $"(ansi yellow)Rensar port 8443...(ansi reset)"
  try { bash -c "fuser -k 8443/tcp 2>/dev/null" } catch { }

  # Vänta tills porten är helt ledig (max 3 sekunder)
  bash -c "for i in {1..30}; do nc -z localhost 8443 2>/dev/null || break; sleep 0.1; done"
  print $"(ansi green)Port 8443 är redo!(ansi reset)"

  bash -c "tsh proxy kube -p 8443 &"
  $env.KUBECONFIG = "/home/simon/.tsh/keys/teleport.simonbrundin.com/admin-kube/teleport.simonbrundin.com/localproxy-8443-kubeconfig"
  # tsh proxy kube -p 8443
  print $"(ansi green)inloggning lyckades!(ansi reset)"
  sleep 2sec
  kubectl get nodes

}

# Kubernetes Dashboard
def "main kubernetes dashboard" [] {
  if ((simon ip | to text) | str contains "192.168.4.1") {
    simon vpn up
  }
  k9s -c 'pods' -A --logoless --headless
}

# Godgänn alla CSR
def "main kubernetes approve csr" [] {
  kubectl get csr --no-headers | awk '/Pending/ {print $1}' | xargs -r kubectl certificate approve
  print $"(ansi green)Alla Pending CSR har godkänts(ansi reset)"
}

# Force delete pod
def "main kubernetes delete pod" [] {
  # Lista namespaces
  let namespaces = (kubectl get namespaces -o json | from json | get items | get metadata.name)
  let selected_namespace = fzfSelect $namespaces
  if ($selected_namespace | is-empty) {
    print "❌ Inget namespace valt. Avbryter."
    return
  }
  # Lista pods i valt namespace
  let pods = (kubectl get pods -n $selected_namespace -o json | from json | get items | get metadata.name)  
  let selected_pod = fzfSelect $pods
  if ($selected_pod | is-empty) {
    print "❌ Ingen pod vald. Avbryter."
    return
  }
  kubectl delete pod $selected_pod -n $selected_namespace --grace-period=0 --force
}


# Debug Kubernetes-pod
def "main kubernetes debug" [name = ""] {

  def select-pod [] {
    # Hämta poddar som matchar villkoren
    let pods = (kubectl get pods -A | detect columns | where ( $it.STATUS != "Running" and $it.NAME =~ $name ))

    # Skapa en lista med pod-info för visning (NAMESPACE och NAME)
    let pod_list = ($pods | each { |row| $"($row.NAMESPACE)/($row.NAME) - ($row.STATUS)" })

    # Om ingen pod matchar, avsluta
    if ($pod_list | is-empty) {
      print $"Inga poddar hittades med status != Running och namn innehållande ($name)"
      return
    }

    # Låt användaren välja en pod
    let selected = ($pod_list | input list -f "Välj en pod:")

    # Extrahera NAMESPACE och NAME från valet
    let parts = ($selected | split row " - " | get 0 | split row "/")
    let namespace = ($parts | get 0)
    let name = ($parts | get 1)

    # Visa vald pod eller meddela om ingen valdes
    if ($selected | is-empty) {
      print "Ingen pod vald."
    } else {
      print $"Vald pod: ($name)"
    }
    print $"NAMESPACE: ($namespace), NAME: ($name)"
    let status = (kubectl get pod -n $namespace $name -o yaml | yq '.status')
    # kubectl describe pod -n $namespace $name | bat 
    # echo $"NAMESPACE: ($namespace), NAME: ($name)"
    # Här kan du lägga till fler kommandon, t.ex. kubectl describe
    let describe = (kubectl describe pod -n $namespace $name)
    $"($describe)\n\nStatus:\n($status)" | cb
    print $"(ansi green)Kopierat till Clipboard(ansi reset)"
  }

  # Kör funktionen
  select-pod

}

# Ta bort finalizers för kubernetesresurs
def "main kubernetes remove finalizers" [] {
  # Steg 1: Välj namespace
  let namespaces = (kubectl get namespaces -o json | from json | get items | get metadata.name)
  let selected_namespace = fzfSelect $namespaces

  if ($selected_namespace | is-empty) {
    print "❌ Inget namespace valt. Avbryter."
    return
  }

  # Steg 2: Hämta resurstyper som fungerar i namespace
  let resource_types = (
    kubectl api-resources --namespaced=true --verbs=list -o name
    | lines
    | where {|r| (kubectl get $r -n $selected_namespace --ignore-not-found | complete).exit_code == 0 }
  )

  # Steg 3: Bygg lista över resursnamn per typ
  let components = (
    $resource_types
    | each {|type|
      kubectl get $type -n $selected_namespace -o json
      | from json
      | get items
      | each {|item| $"($type)/($item.metadata.name)" }
    }
    | flatten
  )

  # Steg 4: Välj en eller flera resurser via fzf --multi
  let selected_components = fzfSelect $components

  if ($selected_components | is-empty) {
    print "❌ Inga resurser valda. Avbryter."
    return
  }

  # Steg 5: Loopa över alla valda resurser och ta bort finalizers
  $selected_components | each {|selected_component|
    let parts = ($selected_component | split row "/")
    let kind = ($parts | get 0)
    let name = ($parts | get 1)

    print $"🔍 Kollar ($kind)/($name)..."

    let resource_details = (kubectl get $kind $name -n $selected_namespace -o json | from json)
    let has_finalizers = ($resource_details.metadata.finalizers? | is-not-empty)

    if not $has_finalizers {
      print $"ℹ️  ($kind)/($name) har inga finalizers."
    } else {
      print $"⚙️  Tar bort finalizers från ($kind)/($name)..."
      kubectl patch $kind $name -n $selected_namespace -p '{"metadata":{"finalizers":null}}' --type=merge
      let new_details = (try {
        kubectl get $kind $name -n $selected_namespace -o json | from json
      } catch {
          null
        })

      if ($new_details | is-not-empty) and ($new_details.metadata.finalizers? | is-empty) {
        print "✅ Finalizers borttagna!"
      } else {
        print "⚠️  Kunde inte bekräfta att finalizers tagits bort."
      }
    }

  }
}

# Se kubernetesresurser som är deleting
def "main kubernetes deleting" [] {
  kubectl get all,configmaps,secrets,pvc --all-namespaces -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.kind)/\(.metadata.name) (Namespace: \(.metadata.namespace))"'
}

# Se kubernetesresurser som är terminating
def "main kubernetes terminating" [] {
  kubectl api-resources --verbs=list --namespaced=true -o name | xargs -I {} kubectl get {} -n rook-ceph -o json | jq -r '.items[] | select(.metadata.deletionTimestamp != null) | "\(.kind)/\(.metadata.name)"'
}

# Radera kubernetesresurser
def "main kubernetes remove selected" [] {
  # Steg 1: Välj namespace
  let namespaces = (kubectl get namespaces -o json | from json | get items | get metadata.name)
  let selected_namespace = fzfSelect $namespaces

  if ($selected_namespace | is-empty) {
    print "❌ Inget namespace valt. Avbryter."
    return
  }

  # Steg 2: Hämta resurstyper som fungerar i namespace
  let resource_types = (
    kubectl api-resources --namespaced=true --verbs=list -o name
    | lines
    | where {|r| (kubectl get $r -n $selected_namespace --ignore-not-found | complete).exit_code == 0 }
  )

  # Steg 3: Bygg lista över resursnamn per typ
  let components = (
    $resource_types
    | each {|type|
      kubectl get $type -n $selected_namespace -o json
      | from json
      | get items
      | each {|item| $"($type)/($item.metadata.name)" }
    }
    | flatten
  )

  # Steg 4: Välj en eller flera resurser via fzf --multi
  let selected_components = fzfSelect $components

  if ($selected_components | is-empty) {
    print "❌ Inga resurser valda. Avbryter."
    return
  }

  # Steg 5: Loopa över och radera varje resurs
  $selected_components | each {|selected_component|
    let parts = ($selected_component | split row "/")
    let kind = ($parts | get 0)
    let name = ($parts | get 1)

    print $"🗑️  Raderar ($kind)/($name) i namespace ($selected_namespace)..."
    kubectl delete $kind $name -n $selected_namespace
  }

  print "✅ Klart!"
}

# Testa node för longhorn
def "main kubernetes longhorn test" [] {
  # Steg 1: Välj node
  let nodes = (kubectl get nodes -o json | from json | get items | get metadata.name)
  let selected_node = fzfSelect $nodes
  print $"(ansi blue)Vald node: (ansi reset)($selected_node)\n"

  # # Välj sätt
  # print $"(ansi blue)Välj sätt:(ansi reset)"
  # let selected_setting = fzfSelect [spec, 0.spec]
  # print $selected_setting
  print $"(ansi blue)Installationsdisk:(ansi reset)"
  let install_disk = (talosctl get machineconfig -n $selected_node -o yaml | from yaml | get spec | from yaml | get machine.install.disk)
  if $install_disk == "/dev/mmcblk1" {
    print $"(ansi green)($install_disk)(ansi reset)"
  } else {
    print $"(ansi red)($install_disk)(ansi reset)"
  }

  print $"(ansi blue)Installerade tillägg:(ansi reset)"
  let extensions = (talosctl get extensions -n $selected_node | detect columns | get NAME)
  print $extensions

  print $"(ansi blue)Diskar och deras filsystem:(ansi reset)"
  let disks = (talosctl get dv -n $selected_node | detect columns | where ID starts-with "sd" | select ID LABEL)
  print $disks

  print $"(ansi blue)Machineconfig disks:(ansi reset)"
  let machine_disks = (talosctl get machineconfig -n $selected_node -o yaml | from yaml | get spec | from yaml | select machine.disks | to yaml)
  print $machine_disks

}

# Installera ArgoCD
def "main kubernetes install argocd" [] {
  kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml
}
