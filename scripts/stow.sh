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
        local relative_path="${item#$HOME/}"
        local basename=$(basename "$item")

        if [ "$relative_path" != "$item" ]; then
            local target_subpath="$target_dir/$relative_path"
            local target_parent=$(dirname "$target_subpath")
            mkdir -p "$target_parent"
            cp -r "$item" "$target_subpath"
            echo "✓ $item → $target_subpath"
        else
            cp -r "$item" "$target_dir/$basename"
            echo "✓ $item → $target_dir/$basename"
        fi
    done <<< "$selection"

    echo ""
    echo "🧷 Sätter upp dotfiles med stow..."
    BACKUP_DIR="$HOME/.dotfiles-backup/.dotfiles-backup-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$BACKUP_DIR"
    cd "$HOME/repos/dotfiles"
    for dir in */; do
        stow --verbose "$dir" --target="$HOME" || echo "⚠️ Hoppar över $dir"
    done
}
