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
        return 2
    fi

    ~/agent-os/scripts/project-install.sh --overwrite-commands

    if [ $? -eq 0 ]; then
        echo "  ✓ $project_name updated"
        return 0
    else
        echo "  ✗ $project_name failed to update"
        return 1
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
    local skipped=0
    local failed_projects=()
    local skipped_projects=()

    for project in "${projects[@]}"; do
        update_agent_os_project "$project"
        local result=$?
        if [ $result -eq 1 ]; then
            ((failed++))
            failed_projects+=("$(basename "$project")")
        elif [ $result -eq 2 ]; then
            ((skipped++))
            skipped_projects+=("$(basename "$project")")
        fi
    done

    echo ""

    if [ ${#skipped_projects[@]} -gt 0 ]; then
        echo "=== Projects with uncommitted changes (commit to enable update) ==="
        for p in "${skipped_projects[@]}"; do
            echo "  - $p"
        done
        echo ""
    fi

    if [ ${#failed_projects[@]} -gt 0 ]; then
        echo "=== Projects that failed to update ==="
        for p in "${failed_projects[@]}"; do
            echo "  - $p"
        done
        echo ""
    fi

    local success=$(( ${#projects[@]} - failed - skipped ))
    echo "$success/${#projects[@]} projects updated successfully"

    if [ $failed -gt 0 ] || [ $skipped -gt 0 ]; then
        return 1
    fi
}
