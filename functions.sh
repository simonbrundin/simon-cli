#!/bin/bash

# Bash equivalent of fzfSelect from functions.nu
# Takes a list of options as arguments, runs fzf --multi, and returns the selection(s)
fzfSelect() {
    local list=("$@")
    local selection

    # Join list with newlines, pipe to fzf --multi, then get lines
    selection=$(printf '%s\n' "${list[@]}" | fzf --multi)

    # If selection has one line, return it; else return as array (but Bash returns string)
    # For simplicity, return space-separated if multiple, or single
    local result
    result=$(echo "$selection" | tr '\n' ' ' | sed 's/ $//')

    echo "$result"
}