#!/bin/bash

# Converted from install.nu

main_install() {
    package="$1"
    if command -v brew >/dev/null 2>&1; then
        brew install "$package"
        brew upgrade
        brew bundle dump --file "$dotfiles_path/brew/.Brewfile" --force
    else
        echo "Brew not found. Please install Homebrew or use your package manager to install $package manually."
    fi
}

main_i() {
    main_install "$1"
}

main_uninstall() {
    package="$1"
    if command -v brew >/dev/null 2>&1; then
        brew uninstall "$package"
        brew upgrade
        brew bundle dump --file "$dotfiles_path/brew/.Brewfile" --force
    else
        echo "Brew not found. Please install Homebrew or use your package manager to uninstall $package manually."
    fi
}