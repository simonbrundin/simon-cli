#!/usr/bin/env nu

# Starta utvecklingsmijö i aktuell mapp
def "main dev" [] {
  with-env { SHELL: "/bin/bash" } {
    # -l för login-shell så PATH initieras korrekt
    bash -lc $"devpod up ."
  }
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
