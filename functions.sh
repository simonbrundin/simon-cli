#!/bin/bash

# Returns one selected line by default; pass --multi to preserve multiple lines.
fzfSelect() {
    local multi=false
    if [ "${1:-}" = "--multi" ]; then
        multi=true
        shift
    fi

    local list=("$@")
    if [ "$multi" = true ]; then
        printf '%s\n' "${list[@]}" | fzf --multi
    else
        printf '%s\n' "${list[@]}" | fzf
    fi
}