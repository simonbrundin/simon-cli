#!/bin/bash

find_agent_os_projects() {
    local repos_path="$HOME/repos"
    local projects=()

    for dir in "$repos_path"/*/; do
        if [ -d "$dir/.claude/commands/agent-os" ]; then
            projects+=("$dir")
        fi
    done

    printf '%s\n' "${projects[@]}"
}

update_agent_os_project() {
    local project_path="$1"
    local project_name=$(basename "$project_path")

    echo "Updating $project_name..."

    cd "$project_path"

    local has_changes=$(git status --porcelain 2>/dev/null)

    if [ -n "$has_changes" ]; then
        echo "  ⚠ Skipping - uncommitted changes"
        return 1
    fi

    ~/agent-os/scripts/project-install.sh --commands-only

    if [ $? -eq 0 ]; then
        echo "  ✓ $project_name updated"
    else
        echo "  ✗ $project_name failed to update"
    fi
}

main_update_agentos() {
    local update_projects="true"

    for arg in "$@"; do
        case "$arg" in
            --no-projects) update_projects="false" ;;
        esac
    done

    echo "Updating Agent OS..."

    local dotfiles_path="$HOME/repos/dotfiles"
    local agent_os_path="$dotfiles_path/agent-os"

    if [ ! -d "$dotfiles_path" ]; then
        echo "Error: Dotfiles repo not found at $dotfiles_path"
        return 1
    fi

    cd "$dotfiles_path"

    echo "Pulling latest changes from dotfiles repo..."
    git pull origin main

    if [ $? -ne 0 ]; then
        echo "Error: Failed to update Agent OS"
        return 1
    fi

    echo "Agent OS updated successfully!"

    if [ "$update_projects" != "true" ]; then
        echo ""
        echo "Skipping project updates (--no-projects flag set)"
        return 0
    fi

    echo ""
    echo "Finding projects with Agent OS..."

    mapfile -t projects < <(find_agent_os_projects)

    if [ ${#projects[@]} -eq 0 ]; then
        echo "No projects found with Agent OS installed."
        return 0
    fi

    echo "Found ${#projects[@]} project(s):"
    for project in "${projects[@]}"; do
        echo "  - $(basename "$project")"
    done
    echo ""

    local failed=0
    for project in "${projects[@]}"; do
        update_agent_os_project "$project" || ((failed++))
    done

    echo ""
    if [ $failed -eq 0 ]; then
        echo "All projects updated successfully!"
    else
        echo "$failed project(s) failed to update."
    fi
}
