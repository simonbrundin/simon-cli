#!/bin/bash

# Converted from ai.nu

main_ai() {
    # Set SOPS age key from 1Password if not already set
    if [ -z "$SOPS_AGE_KEY" ]; then
        export SOPS_AGE_KEY=$(op item get "SOPS" --reveal --fields label="SOPS Private Key" 2>/dev/null)
    fi
    
    if [ -n "$1" ]; then
        /home/simon/repos/agents/bin/agent "$@"
    else
        /home/simon/repos/agents/bin/agent --tui
    fi
}

main_ai_tui() {
    # Check if a feature name was provided
    if [ -n "$2" ]; then
        /home/simon/repos/agents/bin/agent --workflow "$2"
    else
        /home/simon/repos/agents/bin/agent --tui
    fi
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
