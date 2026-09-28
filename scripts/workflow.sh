#!/bin/bash

# Converted from workflow.nu

main_ci() {
    local project="${1:-}"
    shift || true
    local should_push=false multi_arch=false tag=""
    local password vault_token
    local -a dagger_args

    while [ "$#" -gt 0 ]; do
        case "$1" in
            --push) should_push=true ;;
            --multi) multi_arch=true ;;
            --tag)
                if [ "$#" -lt 2 ]; then
                    echo "Usage: simon ci plan [--push] [--multi] [--tag <tag>]" >&2
                    return 2
                fi
                tag="$2"
                shift
                ;;
            *)
                echo "Okänt CI-argument: $1" >&2
                return 2
                ;;
        esac
        shift
    done

    if [ "$project" != "plan" ]; then
        echo "Okänt CI-projekt: $project" >&2
        return 2
    fi

    if ! vault token lookup &>/dev/null; then
        password=$(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a) || return 1
        vault login -method=userpass username=simonbrundin "password=$password" || return 1
    fi
    vault_token=$(vault kv get -field=token kv/prod/argo-events/github) || return 1

    dagger_args=(
        call ci
        --image-name plan
        --registry-address ghcr.io/simonbrundin
        --source-dir "$HOME/repos/plan/frontend"
        --tag "$tag"
        --username simonbrundin
        --secret "$vault_token"
    )
    [ "$multi_arch" = true ] && dagger_args+=(--multiArch)
    [ "$should_push" = true ] && dagger_args+=(--push)

    (
        cd "$HOME/repos/deployment-pipeline/dagger-modules/pipeline" || exit 1
        dagger "${dagger_args[@]}"
    )
}