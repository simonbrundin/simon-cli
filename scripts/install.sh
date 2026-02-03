#!/bin/bash

# Converted from install.nu

main_install() {
    local package="$1"
    local dotfiles_path="$HOME/repos/dotfiles"

    if command -v brew >/dev/null 2>&1; then
        brew install "$package" 2>&1 || echo "Package may already be installed"
        brew upgrade 2>&1 || echo "No upgrades available"
        if [ -d "$dotfiles_path" ]; then
            brew bundle dump --file "$dotfiles_path/brew/.Brewfile" --force 2>/dev/null
        else
            echo "Warning: Dotfiles path not found at $dotfiles_path"
        fi
    else
        echo "Brew not found. Please install Homebrew or use your package manager to install $package manually."
    fi
}

main_i() {
    main_install "$1"
}

main_uninstall() {
    local package="$1"
    local dotfiles_path="$HOME/repos/dotfiles"

    if command -v brew >/dev/null 2>&1; then
        brew uninstall "$package" 2>&1 || echo "Package may not be installed"
        brew upgrade 2>&1 || echo "No upgrades available"
        if [ -d "$dotfiles_path" ]; then
            brew bundle dump --file "$dotfiles_path/brew/.Brewfile" --force 2>/dev/null
        fi
    else
        echo "Brew not found. Please install Homebrew or use your package manager to uninstall $package manually."
    fi
}