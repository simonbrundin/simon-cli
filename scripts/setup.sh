#!/bin/bash

# Converted from setup.nu

main_bootstrap_mac() {
    # Installera Homebrew ifall det saknas
    if ! command -v brew &> /dev/null; then
        echo -e "\033[31mHomebrew saknas, installera det först\033[0m"
        bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
    fi

    # Sätt keyrepeat rate
    defaults write -g KeyRepeat -int 1
    defaults write -g InitialKeyRepeat -int 20

    # Setup Dotfiles path
    if [ -z "$dotfiles_path" ]; then
        read -p "Exakt path till dotfiles: " -e dotfiles_path
        dotfiles_path=${dotfiles_path:-"/Users/simon/repos/devenv/.config"}
    fi
    CONFIG_DIR="$dotfiles_path"
    SKETCHYBAR_THEME="sketchybar"
    NEOVIM_DISTRO="neovim/lazyvim"
    SKETCHYBAR_CONFIG="$dotfiles_path/$SKETCHYBAR_THEME"

    # Skapa symlinks för dotfiles
    echo -e "\033[34mSetting up symlinks for dotfiles\033[0m"
    declare -a symlinks=(
        "nushell:$HOME/Library/Application Support/nushell"
        "btop:$HOME/.config/btop"
        "ghostty:$HOME/Library/Application Support/com.mitchellh.ghostty"
        "ghostty:$HOME/.config/ghostty"
        "$SKETCHYBAR_THEME:$HOME/.config/sketchybar"
        "$NEOVIM_DISTRO:$HOME/.config/nvim"
        "tmux/.tmux.conf:$HOME/.tmux.conf"
        "starship/starship.toml:$HOME/.config/starship.toml"
        "tmux/.gitmux.conf:$HOME/.gitmux.conf"
        "sesh/sesh.toml:$HOME/.config/sesh/sesh.toml"
        "tmuxinator:$HOME/.config/tmuxinator"
        "k9s:$HOME/Library/Application Support/k9s"
        "opencode:$HOME/.config/opencode"
        "agent-os:$HOME/.agent-os"
        "claude:$HOME/.claude"
        "mcphub:$HOME/.config/mcphub"
        "crush:$HOME/.config/crush"
        "yazi:$HOME/.config/yazi"
    )

    for symlink in "${symlinks[@]}"; do
        echo "---------------------"
        IFS=':' read -r target_part source <<< "$symlink"
        target="$dotfiles_path/$target_part"
        echo "target $target"
        echo "source $source"

        if [ -e "$source" ]; then
            rm -rf "$source"
            ln -s "$target" "$source"
            echo -e "\033[32mRecreated symlink\033[0m"
            continue
        fi
        ln -s "$target" "$source"
        echo -e "\033[32mCreated symlink\033[0m"
    done

    # Install packages
    echo "---------------------"
    echo -e "\033[34mInstalling packages\033[0m"
    brew tap arl/arl
    brew bundle --file "$dotfiles_path/brew/.Brewfile"

    # Uppdatera alla Home
    brew update
    brew upgrade
    brew cleanup

    # Start Yabai
    echo -e "\033[34mStarting Yabai\033[0m"
    yabai --start-service
    yabai --restart-service
    echo -e "\033[32mSketchybar started\033[0m"

    # Start Sketchybar
    echo -e "\033[34mStarting Sketchybar\033[0m"
    brew services start sketchybar
    brew services restart felixkratz/formulae/sketchybar
    sketchybar --reload
    echo -e "\033[32mSketchybar started\033[0m"

    # Setup MacOS
    echo "---------------------"
    echo -e "\033[34mSetting up MacOS\033[0m"
    nu "$dotfiles_path/macos/settings.nu"
}

main_setup_argocd() {
    # Installera Gateway-API CRDs
    kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.0.0/standard-install.yaml

    # Kontrollera om namespace argocd redan finns
    if kubectl get ns -o json | jq -e '.items[] | select(.metadata.name == "argocd")' > /dev/null; then
        echo "Namespace 'argocd' finns redan, hoppar över skapandet."
    else
        kubectl create namespace argocd
    fi

    # Installera ArgoCD HA-manifest
    kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/ha/install.yaml

    # Installera App of Apps
    kubectl apply -f /Users/simon/Repos/infrastructure/Kubernetes/root-argocd-app.yml

    # Patcha config map för att UI ska gå att komma åt
    kubectl patch configmap -n argocd argocd-cmd-params-cm --patch-file /Users/simon/Repos/infrastructure/Kubernetes/argocd-cmd-params-patch.yaml

    # Logga lösenordet till Adminpanelen
    echo "-------------------------------------------------"
    echo -e "\033[34mLösenord till Adminpanelen\033[0m"
    password=$(kubectl get secret argocd-initial-admin-secret -n argocd -o jsonpath={.data.password} | base64 -d)
    echo "$password"
    echo "$password" | cb copy
}