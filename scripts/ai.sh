#!/bin/bash

# Converted from ai.nu

main_ai() {
    eval "$AI_AGENT"
}

main_ai_change_agent() {
    agents=("opencode" "crush" "claude")
    selected=$(fzfSelect "${agents[@]}")
    export AI_AGENT="$selected"
    echo -e "\033[32mAI agent uppdaterad till $AI_AGENT\033[0m"
}

main_ai_set_agent() {
    env_file="$HOME/Library/Application Support/nushell/env.nu"  # Keep for now
    agents=("opencode" "crush" "claude")
    selected=$(fzfSelect "${agents[@]}")

    if grep -q 'AI_AGENT' "$env_file"; then
        sed -i "s/\$env\.AI_AGENT = .*/\$env.AI_AGENT = '$selected'/" "$env_file"
    else
        echo "\$env.AI_AGENT = '$selected'" >> "$env_file"
    fi
    echo -e "\033[32mAI agent satt till $selected i env.nu\033[0m"
}