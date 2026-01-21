#!/bin/bash

# Converted from git.nu

main_clone() {
    name="$1"
    git clone "git@github.com:simonbrundin/$name.git" "$HOME/repos/$name"
    repo_path="$HOME/repos/$name"
    if [ -d "$repo_path" ]; then
        cd "$repo_path"
    else
        echo "Failed to clone or directory not found: $repo_path"
    fi
}