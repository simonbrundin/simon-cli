#!/usr/bin/env nu

# Kort: td
# def "main td" [...args] { simon talos dashboard ...$args }


# Talos Dashboard
def "main talos dashboard" [
    ip = "10.10.10.11"      # Node IP-adress
] {
  let nodes = (open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes)
  mut nodesString = ""
  for node in $nodes {
    if ($node.initialized == true) {
    $nodesString += $"($node.name),"

    }
  }
  $nodesString = $nodesString | str substring 0..-2
    talosctl dashboard -n $nodesString

}

# Uppradera Talos med ny config
def "main talos upgrade" [] {
  let latestVersions: list = (http get "https://api.github.com/repos/siderolabs/talos/releases?per_page=5" | select tag_name | get tag_name)
  print $"(ansi blue)Vilken version vill du installera?(ansi reset)"
  let selectedVersion  = fzfSelect $latestVersions
  let nodes: list = (kubectl get nodes | detect columns | get NAME)
  print $"(ansi blue)Vilka noder vill du uppdatera?(ansi reset)"
  let selectedNodes: list = fzfSelect $nodes
  let selectedNodesString: string = ($selectedNodes | str join ",")
  print $"(ansi blue)Ange Schematic ID:(ansi reset)"
  let schematicID = (input)
  talosctl upgrade --image factory.talos.dev/installer/($schematicID):($selectedVersion) -n $selectedNodesString
  # $selectedNodes | each {
  #    | node | talosctl upgrade --image factory.talos.dev/installer/($schematicID):($selectedVersion) -n $selectedNodesString
  #  } 

}

# Uppdatera Talos-config för alla noder eller en specifik nod
def "main talos update config" [nodnamn?: string] {
  # Gå till rätt katalog där dina Talos-filer (nodes.yaml, secrets.yaml, patches/) finns
  cd /home/simon/repos/infrastructure/talos

    # Hämta inloggningsuppgifter mot Talos från 1Password
    # Skapa .op-katalogen om den inte finns
    mkdir ~/.op
    chmod 700 ~/.op
    op signin --raw | save ~/.op/session --force
  print (pwd)
  ls
    op read op://talos/secrets/secrets.yaml -o secrets.yaml -f
    op read op://talos/talosconfig/talosconfig -o talosconfig -f
   chmod 666 secrets.yaml
 chmod 666 talosconfig
  # Ladda YAML-filen med nodinformation
  let nodes = (open nodes.yaml | get nodes)
  let cluster_name = "cluster1"
  let endpoint = "https://10.10.10.10:6443"  # IP för din controlplane
  let config_dir = "generated"  # Katalogen där konfigurationer sparas

  # Bestäm vilka noder som ska uppdateras
  let target_nodes = if ($nodnamn | is-empty) {
    print "Uppdaterar alla noder..."
    $nodes
  } else {
    let found_node = ($nodes | where name == $nodnamn | first)
    if ($found_node | is-empty) {
      print $"Ingen nod med namn ($nodnamn) hittades."
      return
    }
    print $"Uppdaterar endast noden ($nodnamn)..."
    [$found_node]
  }

  # VIKTIG FIX: Ta bort hela 'generated'-katalogen och skapa den på nytt.
  # Detta säkerställer en ren start och undviker "open generated: is a directory" fel.
  if ($config_dir | path exists) {
    rm -rf $config_dir
  }
  mkdir $config_dir

  # Loopa igenom de noder som ska uppdateras
  for $node in $target_nodes {
    print $"Bearbetar nod: ($node.name) med IP ($node.ip)"

    # Hantera patchar för noden
    mut nodePatches = $node.patches | default "" | each {|patch| $"--config-patch=@patches/($patch | into string)"} | str join ' '

    if $nodePatches == "--config-patch=@patches/" {
      print $"Inga patchar hittades för noden ($node.ip)"
      $nodePatches = "" # Se till att det är en tom sträng om inga patchar finns
    } else {
      print $"Patchar: ($nodePatches)"
    }

    # Bestäm vilken output-typ som ska genereras (worker, controlplane, eller båda)
    let output_types = "controlplane,worker,talosconfig"

    
    # Bygg upp 'talosctl gen config'-kommandot som en lista av strängar.
    # Detta är den mest robusta metoden för att hantera argument i Nushell.
    mut base_cmd = [
      "talosctl" "gen" "config"
      $cluster_name
      $endpoint
      $"--output-types=($output_types)"
      "--with-docs=false"
      "--with-examples=false"
      "--config-patch-control-plane=@patches/controlplane.yaml"
      "--config-patch-worker=@patches/worker.yaml"
      "-o" $config_dir
      "--with-secrets=secrets.yaml"
      "--force"
      "--config-patch=@patches/all.yaml"
    ]

    if $node.role == "worker" {
      $base_cmd = ($base_cmd | append $"--config-patch-worker=@patches/disks/($node.name).yaml")
    }

    # Lägg till nodspecifika patchar om de finns
    let full_cmd = if ($nodePatches | is-empty) {
      $base_cmd
    } else {
      # Dela upp patch-strängen i separata argument
      $base_cmd | append ($nodePatches | split row ' ')
    }
    
    # Skriv ut kommandot för felsökning
    print $"Kör kommando: (do { $full_cmd | str join ' ' })"

    # Kör kommandot externt
    run-external ...$full_cmd
    print $"Genererar konfiguration för noden ($node.ip)"

    sleep 2sec # Ge systemet tid att skriva filerna

    let config_file = $"($config_dir)/($node.role).yaml"
    
    # Kontrollera att filen faktiskt skapades
    if not ($config_file | path exists) {
      print $"FEL: Konfigurationsfilen ($config_file) skapades INTE! Kontrollera Talosctl-utdata ovan."
      continue # Gå till nästa nod om filen inte finns
    }
     

    # Applicera konfigurationen på noden
    if $node.initialized == false {
      print $"Noden ($node.ip) är inte initialiserad, applicerar konfigurationen."
      talosctl apply-config --insecure --nodes $node.ip --file $config_file
    } else {
      print $"Noden ($node.ip) är redan initialiserad, applicerar konfigurationen."
      # talosctl --talosconfig generated/talosconfig apply-config --nodes $node.ip --file $config_file --endpoints $endpoint
      talosctl --talosconfig talosconfig apply-config --nodes $node.ip --file $config_file
      print "klart"
    }

    # Namnge noden
    print $"Namnger noden ($node.ip) till ($node.name)"
    talosctl --talosconfig talosconfig patch mc -p $'{"machine":{"network":{"hostname":"($node.name)"}}}' -n $node.ip

    print "-----------------------------"
  }

  let message = if ($nodnamn | is-empty) {
    "Konfiguration har applicerats på alla noder."
  } else {
    $"Konfiguration har applicerats på noden ($nodnamn)."
  }
  print $message
  # rm secrets.yaml
    # rm -rf $config_dir
}

# Talos health
def "main talos health" [] {

  # Skapa listor för controlplane och worker noder
  let controlplanes = open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes | where role == "controlplane" | get ip | str join ','
  let workers = open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes | where role == "worker" | get ip | str join ','
  print $controlplanes
  print $workers
  # Kör talosctl health-kommandot
  # talosctl health --control-plane-nodes ($controlplanes) --worker-nodes ($workers)
  talosctl health -n 10.10.10.10

}

# Talos health
def "main talos update kubeconfig" [] {
    let controlplanes = open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes | where role == "controlplane" | get ip | str join ','

 talosctl kubeconfig /home/simon/repos/infrastructure/talos/kubeconfig
}

# Reboot all Talos nodes
def "main talos reboot all" [] {

  let controlplanes = open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes | where role == "controlplane" | get ip | str join ','
  let workers = open /home/simon/repos/infrastructure/talos/nodes.yaml | get nodes | where role == "worker" | get ip | str join ','
  let nodes = $controlplanes + "," + $workers
  talosctl reboot -n $nodes 
}
