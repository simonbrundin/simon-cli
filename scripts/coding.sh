#!/bin/bash

# Converted from coding.nu

main_dev() {
    ./dev.nu  # Assuming dev.nu exists, or convert if needed
}

main_devpod_delete() {
    selectedDevpod=$(devpod list | tail -n +4 | awk -F'|' '{print $1}' | tr -d ' ' | fzf)
    devpod delete "$selectedDevpod"
}

main_login_vault() {
    password=$(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a)
    vault login -method=userpass username=simonbrundin password="$password"
}

main_test() {
    packageJsons=$(find . -name "package.json" -not -path "*/node_modules/*" 2>/dev/null)
    for pkg in $packageJsons; do
        dir=$(dirname "$pkg")
        cd "$dir" || continue

        packageManager=$(yq '.packageManager' package.json 2>/dev/null || echo "")
        if [ -n "$packageManager" ]; then
            eval "$packageManager run test"
        else
            bun run test
        fi
        cd - > /dev/null
    done
}

main_commit() {
    main_test
    gitStatusBefore=$(git status)
    lazygit
    gitStatusAfter=$(git status)
    if [ "$gitStatusBefore" != "$gitStatusAfter" ]; then
        xdg-open "https://argoworkflows.simonbrundin.com/workflows/?limit=5&Contains=commit"
    fi
}