#!/usr/bin/env nu
use ../functions.nu  [fzfSelect]

# Starta utvecklingsmijö i aktuell mapp
def "main dev" [] {
  let REPOS_PATH = "/home/simon/repos"
  # let DEVCONTAINER_PATH = "environments/dev"
  let repos = (ls $REPOS_PATH | where type == dir | get name | each { path basename } | sort | prepend ($env.PWD | path basename))
  let selectedRepo = ($repos | str join "\n" | fzf | str trim | str replace -r '\[|\]' '')
  if ($selectedRepo | is-empty) {
    print "❌ Ingen repo vald"
    return
  }
  # cd $"($REPOS_PATH)/($selectedRepo)/($DEVCONTAINER_PATH)"
  # print (pwd)
  #
  # print $"(ansi blue) Letar efter .devcontainer.json...(ansi reset)"
  # let files = ls -a | where name == ".devcontainer.json"
  # if ($files | length) > 0 {
  #   print $"(ansi green) .devcontainer.json hittades!(ansi reset)"
  # } else {
  #   print $"(ansi red) .devcontainer.json hittades inte!(ansi reset)"
  #   let answer = (input "Vill du skapa en .devcontainer.json? (j/n): " | str trim | str downcase)
  #   if ($answer starts-with 'j' or $answer starts-with 'y') {
  #     let devcontainer_content = '{
  #     "name": "Dev Environment",
  #     "image": "mcr.microsoft.com/devcontainers/base:ubuntu"
  #     }'
  #     $devcontainer_content | save .devcontainer.json
  #     print $"(ansi green) .devcontainer.json skapad!(ansi reset)"
  #   }
  # }

  # let selectedProvider = (devpod provider list | ansi strip | lines | skip 3 | each { |line| $line | split row '|' | get 0 | str trim } | str join "\n" | ^fzf)

  let devpodCommand = $"devpod up . --id ($selectedRepo)"
  print $"(ansi blue)Kör `($devpodCommand)`(ansi reset)"
  nu -c $"SHELL=/bin/bash ($devpodCommand)"

}

# Delete Devpod
def "main devpod delete" [] {
  let selectedDevpod = (devpod list | ansi strip | lines | skip 3 | each { |line| $line | split row '|' | get 0 | str trim } | str join "\n" | ^fzf)
  devpod delete $selectedDevpod
}


# Logga in mot Vault
def "main login vault" [] {
  vault login -method=userpass username=simonbrundin password=(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a)
} 


# Kör tester i projektet du befinner dig i
def "main test" [] {
  # Hitta alla package.json-filer i nuvarande mapp och underkataloger
  let packageJsons = (try { ls **/package.json } catch { [] }) | where not ($it.name | into string | str contains "node_modules")
  if (($packageJsons | length) > 0) {
    # Loopa igenom varje package.json
    for pkg in $packageJsons {
      # Hämta mappvägen för package.json
      let dir = ("./" + $pkg.name | into string | str replace -r 'package.json' '')

      # Läs in package.json för att avgöra pakethanterare
      let content = (yq $pkg.name | from json)

      cd $dir

      let packageManager = ($content | get packageManager? | default "")
      if (try { $packageManager } | is-not-empty) {
        run ($packageManager + " run test")
      } else {
        bun run test
      }
      # Bestäm pakethanterare (exempel: om "yarn.lock" finns i samma mapp, använd yarn, annars npm)
      # let use_yarn = (ls $dir | where name == "yarn.lock" | count) > 0

      # Kör tester i den mappen med rätt pakethanterare
      # if $use_yarn {
      #   echo "Kör tester med yarn i $dir"
      #   cd $dir; yarn test; cd -
      # } else {
      #   echo "Kör tester med npm i $dir"
      #   cd $dir; npm test; cd -
      # }
    }

  }

}

# Commit och se Commit Stage i Argo Workflows
def "main commit" [] {
  main test
  let gitStatusBefore = (git status)
  lazygit 
  let gitStatusAfter = (git status)
  if ($gitStatusBefore != $gitStatusAfter) {

    start "https://argoworkflows.simonbrundin.com/workflows/?limit=5&Contains=commit" 
    # k9s -c 'pods /commit' -n argo-events --logoless --headless

    return
    exit 

  }

}
