#!/bin/bash

# Converted from config.nu

main_chezmoi_convert_symlink() {
    read -p "Ange sökväg till symlink: " path
    rsync -aL -- "$path" "$path.real"
    mv "$path" "$path.symlink_backup"
    mv "$path.real" "$path"
    chezmoi add "$path"
}

main_config() {
    tool="${1:-simon}"
    case $tool in
        "simon")
            $EDITOR /Users/simon/Repos/devenv/CLI/simon.sh
            ;;
        "nu")
            $EDITOR "$nushell_path/config.nu"
            ;;
        "vim")
            $EDITOR "/Users/simon/.vimrc"
            ;;
        "colorscheme")
            sh "/Users/simon/repos/devenv/.config/colorscheme/colorscheme-selector.sh"
            ;;
        "ghostty")
            $EDITOR "$HOME/Library/Application Support/com.mitchellh.ghostty/config"
            ;;
        "packages")
            $EDITOR "$XDG_CONFIG_HOME/brew/Brewfile"
            ;;
        "keys")
            $EDITOR "$dotfiles_path/karabiner/karabiner-config.ts"
            ;;
        "pxe packages")
            $EDITOR /Users/simon/Repos/infrastructure/pxe/devbox.json
            ;;
        "nvim")
            $EDITOR "$XDG_CONFIG_HOME/nvim/lazyvim/"
            ;;
    esac
}

main_c() {
    main_config "$1"
}

main_source() {
    tool="${1:-nu}"
    case $tool in
        "nu")
            main_config nu
            ;;
        "keys")
            deno run --allow-env --allow-read --allow-write "$dotfiles_path/karabiner/karabiner-config.ts"
            ;;
    esac
}

main_s() {
    main_source "$1"
}