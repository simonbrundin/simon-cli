#!/usr/bin/env nu

# Kort: Kubernetes
def "main k" [...args] { simon kubernetes ...$args }

def "main kubernetes login certificate" [clustername = ""] {
# Läs in från 1Password
  let kubeconfig_content = (op read "op://talos/kubeconfig/kubeconfig")
  print $"(ansi blue)Från 1Password(ansi reset)"
  # print $kubeconfig_content

  # Skriv till en temporär fil
  let temp_kubeconfig = $"/tmp/kubeconfig-certificate"
  print $"(ansi blue)Path för temp_kubeconfig(ansi reset)"
  print $"(ansi green)($temp_kubeconfig)(ansi reset)"
$kubeconfig_content | save $temp_kubeconfig -f
  print $"(ansi blue)Innehållet i filen(ansi reset)"
  # cat $temp_kubeconfig


  # Sätt miljövariabeln till den temporära filen


  $env.KUBECONFIG = $temp_kubeconfig
  export-env { $env.SPAM = 'eggs' }
  print $"(ansi blue)kubeconfig-variabeln(ansi reset)"
  print $env.KUBECONFIG

let result = (try { kubectl get nodes; true } catch { false })

if $result {
    print $"(ansi green)Inloggning lyckades!(ansi reset)"
} else {
    print $"(ansi red)Inloggning misslyckades – kontrollera certifikat eller nätverk.(ansi reset)"
}
}
def "main kubernetes login teleport" [clustername = ""] {
  # Kontrollera om vi kan komma åt Kubernetes API
  # let can_access = (try { kubectl get nodes; true } catch { false })

  # if not $can_access {
  #   # Hämta lösenord från 1Password
  #   # let teleport_password = (op read op://private/teleport/password --force)
  #   bash -c $"tsh login --proxy=teleport.simonbrundin.com:443 --user=admin --auth=passwordless teleport.simonbrundin.com"
  # } else {
  #   bash -c "tsh login --proxy=teleport.simonbrundin.com:443 --user=admin teleport.simonbrundin.com"
  # }

  # kommandon direkt från teleport

  # Ta bort --auth=local för att möjliggöra WebAuthn/security key
  bash -c "tsh login --proxy=teleport.simonbrundin.com:443 --user=admin --auth=passwordless teleport.simonbrundin.com"
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
def "main kubernetes longhorn test" [node: string?] {
  # Steg 1: Välj node (om inte angiven)
  let nodes = (kubectl get nodes -o json | from json | get items | get metadata.name)
  let selected_node = if ($node | is-not-null) {
    $node
  } else {
    fzfSelect $nodes
  }
  print $"(ansi blue)Vald node: (ansi reset)($selected_node)\n"

  # === LONGHORN SPECIFIK FELINFORMATION ===
  print $"\n(ansi blue)=== Longhorn Volume Status ===(ansi reset)"

  # Hämta alla Longhorn-volymer
  let volumes = (kubectl get volumes.longhorn.io -n longhorn-system -o json | from json | get items)

  # Visa volymer som inte är i "running"-state
  let non_running = ($volumes | where status.state != "running")
  if ($non_running | length) > 0 {
    for vol in $non_running {
      let vol_name = ($vol | get metadata.name)
      let vol_state = ($vol | get status.state)
      let error_msg = (try { $vol | get status.errorMessage } catch { "null" })
      let attach_node = (try { $vol | get status.currentNodeID } catch { "null" })

      print $"  (ansi red)⚠(ansi reset) ($vol_name)"
      print $"      State: (ansi red)($vol_state)(ansi reset)"
      if ($attach_node | str length) > 0 and $attach_node != "null" {
        print $"      Attached to: ($attach_node)"
      }
      if ($error_msg | str length) > 0 and $error_msg != "null" {
        print $"(ansi red)      Error: ($error_msg)(ansi reset)"
      }
    }
  } else {
    print $"(ansi green)  Alla volymer är i running-state(ansi reset)"
  }

  # === LONGHORN NODE STATUS ===
  print $"\n(ansi blue)=== Longhorn Node Status ===(ansi reset)"

  let lhnodes = (kubectl get nodes.longhorn.io -n longhorn-system -o json | from json | get items)

  # Hitta noder med problem
  let nodes_with_issues = ($lhnodes | where {
    let node = $in
    let has_false = (try { ($node | get status.conditions | where status == "False") | length } catch { 0 })
    $has_false > 0
  })

  if ($nodes_with_issues | length) > 0 {
    for lhnode in $nodes_with_issues {
      let node_name = ($lhnode | get metadata.name)
      let conditions = (try { $lhnode | get status.conditions | where status == "False" } catch { [] })

      print $"  (ansi red)⚠(ansi reset) ($node_name)"
      for cond in $conditions {
        let ctype = ($cond | get type)
        let reason = ($cond | get reason)
        let message = ($cond | get message)
        print $"      ($ctype): (ansi red)($reason)(ansi reset)"
        if ($message | str length) > 0 {
          print $"        -> ($message)"
        }
      }
    }
  } else {
    print $"(ansi green)  Alla Longhorn-noder är normala(ansi reset)"
  }

  # === SCHEDULABLE NODER ===
  print $"\n(ansi blue)=== Schedulable Status ===(ansi reset)"

  # Jämför med vald node
  let selected_lhnode = ($lhnodes | where metadata.name == $selected_node)
  if ($selected_lhnode | length) > 0 {
    let schedulable = (try { $selected_lhnode | get status.conditions | where type == "Schedulable" | get status | first } catch { "unknown" })
    let ready = (try { $selected_lhnode | get status.conditions | where type == "Ready" | get status | first } catch { "unknown" })

    if $schedulable == "True" {
      print $"  Schedulable: (ansi green)Yes(ansi reset)"
    } else {
      print $"  Schedulable: (ansi red)No(ansi reset)"
    }
    if $ready == "True" {
      print $"  Ready: (ansi green)Yes(ansi reset)"
    } else {
      print $"  Ready: (ansi red)No(ansi reset)"
    }
  }

  # === KUBERNETES NODE STATUS ===
  print $"\n(ansi blue)=== Kubernetes Node Status ===(ansi reset)"
  let k8s_node = (kubectl get node $selected_node -o json 2>/dev/null | from json)
  if ($k8s_node | is-not-null) {
    let node_ready = (try { $k8s_node.status.conditions | where type == "Ready" | get status | first } catch { "unknown" })
    let node_memory := (try { $k8s_node.status.capacity.memory } catch { "null" })
    let node_allocatable := (try { $k8s_node.status.allocatable.memory } catch { "null" })

    if $node_ready == "True" {
      print $"  Node: (ansi green)Ready(ansi reset)"
    } else {
      print $"  Node: (ansi red)($node_ready)(ansi reset)"
    }
    print $"  Allocatable Memory: ($node_allocatable) / ($node_memory)"
  } else {
    print $"  (ansi red)Node finns inte i Kubernetes(ansi reset)"
  }

  # === LONGHORN PODS PÅ NODEN ===
  print $"\n(ansi blue)=== Longhorn Pods på noden ===(ansi reset)"
  let lh_pods = (kubectl get pods -n longhorn-system -o json | from json | get items | where spec.nodeName == $selected_node)
  if ($lh_pods | length) > 0 {
    for pod in $lh_pods {
      let pod_name = ($pod | get metadata.name)
      let pod_status = ($pod | get status.phase)
      let ready_cnt = (try { ($pod.status.containerStatuses | where ready == true) | length } catch { 0 })
      let total_cnt = (try { ($pod.status.containerStatuses) | length } catch { 0 })
      print $"  ($pod_name): ($pod_status) ($ready_cnt)/($total_cnt)"
    }
  } else {
    print $"  (ansi yellow)Inga Longhorn-pods på denna nod(ansi reset)"
  }

  # === INSTANCE MANAGERS ===
  print $"\n(ansi blue)=== Instance Manager Status ===(ansi reset)"
  let inst_managers = (kubectl get instancemanagers.longhorn.io -n longhorn-system -o json | from json | get items)
  for im in $inst_managers {
    let im_name = ($im | get metadata.name)
    let im_node = (try { $im.spec.nodeID } catch { "null" })
    let im_state = (try { $im.status.currentState } catch { "null" })

    if $im_node == $selected_node {
      if $im_state == "running" {
        print $"  ($im_name): (ansi green)($im_state)(ansi reset)"
      } else {
        print $"  ($im_name): (ansi red)($im_state)(ansi reset)"
      }
    }
  }

  # === DISK RECOVERY / AVAILABLE DISKS ===
  print $"\n(ansi blue)=== Longhorn Disks ===(ansi reset)"
  let lh_disks = (kubectl get disks.longhorn.io -n longhorn-system -o json | from json | get items)
  let disks_on_node = ($lh_disks | where spec.nodeID == $selected_node)
  if ($disks_on_node | length) > 0 {
    for disk in $disks_on_node {
      let disk_name = ($disk | get metadata.name)
      let disk_available := (try { $disk.status.availableStorage } catch { "null" })
      let disk_in_use := (try { $disk.status.inUseStorage } catch { "null" })
      let disk_conditions := (try { $disk.status.conditions | where status == "False" } catch { [] })

      print $"  ($disk_name):"
      print $"    Available: ($disk_available)"
      print $"    In Use: ($disk_in_use)"
      if ($disk_conditions | length) > 0 {
        for cond in $disk_conditions {
          let ctype = ($cond | get type)
          print $"    (ansi red)($ctype): ($cond.reason)(ansi reset)"
        }
      }
    }
  } else {
    print $"  (ansi red)Inga Longhorn-diskar på denna nod(ansi reset)"
  }

  # === TALOS-INFORMATION (för vald nod) ===
  print $"\n(ansi blue)=== Talos Information ===(ansi reset)"

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
