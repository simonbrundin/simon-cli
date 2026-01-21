#!/usr/bin/env nu

# Klona ett av mina GitHub-repen
def "main clone" [name] {
    git clone git@github.com:simonbrundin/($name).git ~/repos/($name)
    let repo_path = ($"~/repos/($name)" | path expand)
    if ($repo_path | path exists) {
        cd $repo_path
    } else {
        echo $"Failed to clone or directory not found: ($repo_path)"
    }
}