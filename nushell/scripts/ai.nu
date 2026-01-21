#!/usr/bin/env nu

# Koda med ai
def "main ai" [] {
  nu -c $env.AI_AGENT
}

# Ändra agent
def "main ai change agent" [] {
      # Låt användaren välja en pod
  let agents = ["opencode", "crush", "claude"] 
    let selected = ($agents | input list -f "Välj en agent:")
  $env.AI_AGENT = $selected
  print $"(ansi green)AI agent uppdaterad till ($env)(ansi reset)"

}

# Välj agent
def "main ai set agent" [] {
  let env_file = $"($env.HOME)/Library/Application Support/nushell/env.nu"
  let lines = open $env_file | lines
  let agents = ["opencode", "crush", "claude"] 
    let selected = ($agents | input list -f "Välj en agent:")
  let new_lines = ($lines | each {|l|
    if ($l | str contains '$env.AI_AGENT') {
      $"$env.AI_AGENT = '($selected)'"
    } else {
      $l
    }
  })
  $new_lines | str join "\n" | save -f $env_file
  if ($lines | where {|l| $l | str contains '$env.AI_AGENT'} | is-empty) {
  # Lägg till raden om den inte finns
  ($lines | append $"$env.AI_AGENT = '($selected)'" | str join "\n" | save -f $env_file)
}
  print $"(ansi green)AI agent satt till ($selected) i env.nu(ansi reset)"
}

