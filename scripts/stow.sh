#!/bin/bash

main_stow() {
    local dotfiles_dir="$HOME/repos/dotfiles"

    if [ ! -d "$dotfiles_dir" ]; then
        echo "❌ $dotfiles_dir finns inte"
        return 1
    fi

    local selection
    selection=$(find / -not -path '*/proc/*' -not -path '*/sys/*' -not -path '*/dev/*' 2>/dev/null | \
                fzf --multi --preview 'ls -la "{}"')

    if [ -z "$selection" ]; then
        echo "❌ Inget valt"
        return 1
    fi

    echo "Ange mappnamn i ~/repos/dotfiles/:"
    read -r folder_name

    if [ -z "$folder_name" ]; then
        echo "❌ Mappnamn krävs"
        return 1
    fi

    local target_dir="$dotfiles_dir/$folder_name"
    mkdir -p "$target_dir"

    while IFS= read -r item; do
        local basename=$(basename "$item")
        cp -r "$item" "$target_dir/$basename"
        echo "✓ Kopierade: $item"
    done <<< "$selection"

    echo ""
    echo "Kör bootstrap..."
    curl -sL bootstrap.simonbrundin.com | bash
}