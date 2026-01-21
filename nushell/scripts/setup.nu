#!/usr/bin/env nu

# Setup my Mac
def "main bootstrap mac" [] {
  # Installera Homebrew ifall det saknas
    if (which brew | is-empty) == true {
        print $"(ansi red) Homebrew saknas, installera det först (ansi reset)"
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    }
    
    # Sätt keyrepeat rate 
    defaults write -g KeyRepeat -int 1
    defaults write -g InitialKeyRepeat -int 20


   
    # Setup Dotfiles path
    if ($env.dotfiles-path? | is-empty) {
        $env.dotfiles-path = input "Exakt path till dotfiles: " --default "/Users/simon/repos/devenv/.config"
    }
    $env.CONFIG_DIR = $env.dotfiles-path
    $env.SKETCHYBAR_THEME = "sketchybar"
    $env.NEOVIM_DISTRO = "neovim/lazyvim"
    $env.SKETCHYBAR_CONFIG = $"($env.dotfiles-path)/($env.SKETCHYBAR_THEME)"
    # Skapa symlinks för dotfiles
    print $"(ansi blue) Setting up symlinks for dotfiles (ansi reset)"
    let symlinks = [ 
        ["nushell", $"($env.HOME)/Library/Application Support/nushell"] # Nushell
        # ["devbox/devbox.json", $"($env.HOME)/.local/share/devbox/global/default/devbox.json"]
        ["btop", $"($env.HOME)/.config/btop"]
    #        ["aerospace/.aerospace.toml", $"($env.HOME)/.aerospace.toml"]
        ["ghostty", $"($env.HOME)/Library/Application Support/com.mitchellh.ghostty"] # Ghostty
        ["ghostty", $"($env.HOME)/.config/ghostty"] # Ghostty
        [$"($env.SKETCHYBAR_THEME)", $"($env.HOME)/.config/sketchybar"] # Sketchybar
        [$"($env.NEOVIM_DISTRO)", $"($env.HOME)/.config/nvim"] # Neovim 
        ["tmux/.tmux.conf", $"($env.HOME)/.tmux.conf"] # Tmux 
        # ["tmux/plugins", $"($env.HOME)/.tmux/plugins"] # Tmux 
        ["starship/starship.toml", $"($env.HOME)/.config/starship.toml"] # Starship
        ["tmux/.gitmux.conf", $"($env.HOME)/.gitmux.conf"] # Gitmux
        ["sesh/sesh.toml", $"($env.HOME)/.config/sesh/sesh.toml"] # Sesh
        ["tmuxinator", $"($env.HOME)/.config/tmuxinator"] # Tmuxinator
        ["k9s", $"($env.HOME)/Library/Application Support/k9s"] # K9s
        ["opencode", $"($env.HOME)/.config/opencode"] # OpenCode
        ["agent-os", $"($env.HOME)/.agent-os"] # Agent OS
        ["claude", $"($env.HOME)/.claude"] # Claude Code
        ["mcphub", $"($env.HOME)/.config/mcphub"] # MCPHub
        ["crush", $"($env.HOME)/.config/crush"] # Crush
        ["yazi", $"($env.HOME)/.config/yazi"] # Crush
         
    ]
    
    for symlink in $symlinks {
        print "---------------------"
        let target = $"($env.dotfiles-path)/($symlink | get 0)"
        print ("target " + $target)
        let source = $symlink | get 1
        print ("source " + $source)

        

        if ($source | path exists) == true {
            rm -r $source
            ln -s $target $source
            print $"(ansi green) Recreated symlink (ansi reset)"
            continue
        }
        ln -s $target $source
        print $"(ansi green) Created symlink (ansi reset)" 
    }

    # Install packages
    print "---------------------"
    print $"(ansi blue) Installing packages (ansi reset)"
        # Add taps  
        brew tap arl/arl   
        brew bundle --file $"($env.dotfiles-path)/brew/.Brewfile"
    
    # Uppdatera alla Home
    brew update
    brew upgrade
    brew cleanup

    # # Start Aerospace
    # print $"(ansi blue) Starting Aerospace (ansi reset)"
    # start /Applications/AeroSpace.app
    # print $"(ansi green) Aerospace started (ansi reset)" 
  
    # Start Yabai
    print $"(ansi blue) Starting Yabai (ansi reset)"
    yabai --start-service
    yabai --restart-service
    print $"(ansi green) Sketchybar started (ansi reset)" 
    
    # Start Sketchybar
    print $"(ansi blue) Starting Sketchybar (ansi reset)"
    brew services start sketchybar
    brew services restart felixkratz/formulae/sketchybar
    sketchybar --reload
    print $"(ansi green) Sketchybar started (ansi reset)" 

    # Setup MacOS
    print "---------------------"
    print $"(ansi blue) Setting up MacOS (ansi reset)"
    nu $"($env.dotfiles-path)/macos/settings.nu"
    
}    

# Setup ArgoCD
def "main setup argocd" [] {
  # Installera Gateway-API CRDs
  kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

  # Kontrollera om namespace argocd redan finns
  if (kubectl get ns -o json | from json | get items | any { |it| $it.metadata.name == argocd }) {
    echo "Namespace 'argocd' finns redan, hoppar över skapandet."
  } else {
    kubectl create namespace argocd
  }

  # Installera ArgoCD HA-manifest
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml

  # Installera App of Apps
  kubectl apply -f /Users/simon/Repos/infrastructure/Kubernetes/root-argocd-app.yml
  
  # Patcha config map för att UI ska gå att komma åt
  kubectl patch configmap -n argocd argocd-cmd-params-cm --patch-file /Users/simon/Repos/infrastructure/Kubernetes/argocd-cmd-params-patch.yaml

  # Logga lösenordet till Adminpanelen
  print "-------------------------------------------------"
  print $"(ansi blue)Lösenord till Adminpanelen (ansi reset)"
  let password = (kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d)
  print $password
  $password | cb copy
}
