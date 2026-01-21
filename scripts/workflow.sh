#!/bin/bash

# Converted from workflow.nu

main_ci() {
    project="$1"
    shift
    push=false
    multi=false
    tag=""

    while [[ $# -gt 0 ]]; do
        case $1 in
            --push) push=true ;;
            --multi) multi=true ;;
            --tag) tag="$2"; shift ;;
            *) ;;
        esac
        shift
    done

    # Säkerställ inloggning till Vault
    if ! vault token lookup &>/dev/null; then
        password=$(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a)
        vault login -method=userpass username=simonbrundin password="$password"
    fi

    startingDirectory=$(pwd)

    case $project in
        "plan")
            cd /Users/simon/repos/deployment-pipeline/dagger-modules/pipeline || return
            cmd="dagger call ci --image-name plan --registry-address ghcr.io/simonbrundin --source-dir /Users/simon/repos/plan/frontend --tag $tag --username simonbrundin --secret $(vault kv get -field=token kv/prod/argo-events/github)"
            if [ "$multi" = true ]; then
                cmd="$cmd --multiArch"
            fi
            eval "$cmd"
            ;;
    esac

    cd "$startingDirectory"
}