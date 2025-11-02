# CRUSH.md - Simon CLI Agent Memory

## Build/Lint/Test Commands

### Running the CLI

```bash
./simon
# or
nu simon
```

### Single Test Commands

- Test substring: `simon test` (empty function, needs implementation)
- Kubernetes tests: `kubectl` commands in kubernetes.nu for various K8s operations
- Talos cluster tests: `talosctl` commands in talos.nu for cluster management

### Infrastructure Commands

- Setup Mac: `simon setup mac` - installs Homebrew, sets up dotfiles symlinks
- VPN management: `simon vpn up/down` - connects/disconnects UniFi Teleport VPN
- Disk cleanup: `simon disk <path>` - analyzes disk usage with gdu-go
- Speed test: `simon speed` - runs internet speed test
- IP addresses: `simon ip` - shows local IP addresses

### Development Commands

- Git operations: `simon commit` - commits and opens Argo Workflows dashboard
- Package installation: `simon install <package>` - installs Brew package and updates Brewfile
- Configuration: `simon config <tool>` - opens configuration files for various tools
- AI agents: `simon ai set agent` - switches between opencode and crush agents

### Infrastructure Management

- Kubernetes operations: `simon k <subcommand>` - kubernetes management commands
- Talos cluster: `simon talos <command>` - Talos Linux cluster operations
- PXE setup: `simon setup pxe` - sets up PXE boot server
- ArgoCD setup: `simon setup argocd` - installs ArgoCD in cluster

## Code Style Guidelines

### Nushell Language Conventions

```nushell
# Function definition pattern
def "main command name" [] {
    # function body
}

# Variable naming: lowercase with underscores
let selected_command = fzfSelect $commands

# String interpolation with parentheses
print $"Message: ($variable)"

# Command chaining with pipelines
$list | where condition | each { |item| ... }

# External command execution with ^ prefix
^git init

# Error handling pattern
try {
    # risky operation
} catch { |err|
    print $"Error: ($err)"
}

# List operations
$list | get index
$list | where {|x| $x matches $pattern}
$list | each {|item| $"Item: ($item)"}

# Conditional execution
if $condition {
    # true branch
} else {
    # false branch
}

# Path operations
$"/path/to/($filename)"
$"($env.HOME)/.config"
```

### File Organization

- Main CLI: `simon` - main entry point that sources scripts
- Scripts directory: separate files for different functionality domains
- Configuration: environment variables stored with `$env.` prefix
- Constants: simple string/int assignments at script start

### Formatting Rules

- Use 4 spaces for indentation (standard Nushell)
- Single quotes for literal strings: `'literal'`
- Double quotes for interpolation: `$"interpolated ($var)"`
- Empty line between function definitions
- Comments on their own line: `# comment`

### Naming Conventions

- Function names: `main` prefix for CLI commands like `"main setup mac"`
- Variables: snake_case like `$selected_namespace`
- Environment variables: UPPERCASE like `$env.HOME`
- Files: lowercase with extensions like `kubernetes.nu`

### Error Handling Patterns

```nushell
# Check if empty before processing
if ($result | is-empty) {
    print "No results"
    return
}

# Check file existence
if ($path | path exists) { ... }

# Complete command with error checking
let result = (command arg | complete)
if $result.exit_code != 0 {
    print $"Command failed: ($result.stderr)"
}

# Try-catch for risky operations
try {
    risky_operation
} catch {
    print "Operation failed"
}
```

### CLI Command Patterns

```nushell
# Interactive selection with fzf
def fzfSelect [list: list] {
  let selection = ($list | str join "\n" | fzf --multi | lines)
  if ($selection | length) == 1 {
    return ($selection | first)
  } else {
    return $selection
  }
}

# ANSI colored output
print $"(ansi green)Success message(ansi reset)"
print $"(ansi red)Error message(ansi reset)"
```

### Import/Dependency Management

- Standard Nushell built-ins used extensively
- External tools: `kubectl`, `talosctl`, `gh`, `git`, `brew`
- Source pattern: `source scripts/setup.nu`
- Homebrew for package management: `brew install <package>`

### Testing Strategy

- Manual testing through CLI commands
- Integration tests via actual infrastructure commands
- Status checks with `kubectl`, `talosctl` commands
- Error verification through exit codes and stderr output

### Commit Message Style

Following the project's `simon commit` workflow:

- Conventional commits not strictly used, but clean descriptive messages
- Commit and trigger Argo Workflows CI/CD automatically
- Code review process through Argo Workflows dashboard

💘 Generated with Crush
Co-Authored-By: 💘 Crush <crush@charm.land></content>
<parameter name="file_path">CRUSH.md
