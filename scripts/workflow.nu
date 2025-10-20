#!/usr/bin/env nu

# Kör CI-workflow
def "main ci" [
  project: string
  --push
  --multi
  --tag: string
] {
  # Säkerställ inloggning till Vault
  let token_check = (try { vault token lookup | complete | get exit_code } catch { 1 })
  if ($token_check != 0) {
    vault login -method=userpass username=simonbrundin password=(bw get password a2041c06-1cb1-4eb5-a609-b35300c9d21a)
  }
  let startingDirectory = (pwd)
  match $project {
    "plan" => {
            cd /Users/simon/repos/deployment-pipeline/dagger-modules/pipeline 
      (dagger call ci
        --image-name plan 
        --registry-address ghcr.io/simonbrundin 
        --source-dir /Users/simon/repos/plan/frontend
        --tag $tag 
        --username simonbrundin 
        --secret (vault kv get -field=token kv/prod/argo-events/github)
        (if $multi { "--multiArch" } else {  })

        # (if $push { "--push" } else { "" })
        # (if $push { "--push" } else { "" })
      )
    },
  }
  cd $startingDirectory
}
