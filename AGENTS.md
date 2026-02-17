# AGENTS.md - Agent Guidelines for simon-cli

## Project Overview

This is a personal CLI tool written in **Bash** (converted from Nushell). It provides commands for infrastructure management, development workflows, and system operations.

## Build/Lint/Test Commands

### Running the CLI

```bash
./simon              # Run interactive CLI
./simon --help       # Show help
```

### Single Test Commands

This project has no dedicated unit tests for the Bash code itself. Testing is done via:

- **Run `main_test` function**: `./simon test` - finds all `package.json` files and runs their test suites
- **Manual testing**: Run specific CLI commands and verify output
- **Integration testing**: Use actual infrastructure tools (`kubectl`, `talosctl`, `gh`)

### Package.json Projects

When working on projects referenced by this CLI (e.g., in `$HOME/repos/`), use:

```bash
bun test             # Run tests (primary package manager)
npm test             # Alternative
pnpm test            # Alternative
```

---

## Code Style Guidelines

### File Organization

```
simon                 # Main entry point (sources all scripts)
functions.sh          # Shared utility functions
scripts/
  git.sh              # Git operations
  kubernetes.sh       # Kubernetes commands
  talos.sh            # Talos Linux cluster
  coding.sh           # Development workflows
  install.sh          # Package installation
  config.sh           # Configuration file editing
  ...
```

### Function Naming

- CLI commands use `main_<command>` naming: `main_clone()`, `main_install()`
- Internal utilities: descriptive names like `fzfSelect()`
- Convert underscores to spaces for CLI: `main_github_create` → `github create`

### Variable Naming

```bash
# Variables: lowercase with underscores
local repo_path="$HOME/repos/$name"
local selected_command="install"

# Constants: UPPERCASE
local WIREGUARD_DIR="$HOME/.wireguard"
```

### String Handling

```bash
# Literal strings: single quotes
echo 'No results found'

# Interpolation: double quotes
echo "Running command: $selected_command"
echo "Failed: $error_message"

# ANSI colors
echo -e "\033[32m✅ Success\033[0m"
echo -e "\033[31m❌ Error: $err\033[0m"
```

### Function Patterns

```bash
main_my_command() {
    local arg1="$1"
    local arg2="${2:-default}"
    
    # Validate inputs
    if [ -z "$arg1" ]; then
        echo "Usage: simon my-command <arg1> [arg2]"
        return 1
    fi
    
    # Check command availability
    if ! command -v kubectl >/dev/null 2>&1; then
        echo "❌ kubectl not found"
        return 1
    fi
    
    # Main logic
    kubectl get pods
    
    return 0
}
```

### Command Execution

```bash
# Check exit code
kubectl get pods
if [ $? -ne 0 ]; then
    echo "❌ Command failed"
    return 1
fi

# Capture output
local output=$(command arg1 arg2)

# Use local for all variables in functions
local result
result=$(some_command)
```

### Error Handling

```bash
# Validate required arguments
if [ -z "$1" ]; then
    echo "Error: missing required argument"
    echo "Usage: simon install <package>"
    return 1
fi

# Check file/directory existence
if [ ! -d "$repo_path" ]; then
    echo "❌ Directory not found: $repo_path"
    return 1
fi

# Check command availability
if ! command -v brew >/dev/null 2>&1; then
    echo "❌ Homebrew not installed"
    return 1
fi

# Handle errors from piped commands
some_command || {
    echo "❌ Command failed"
    return 1
}
```

### Conditionals

```bash
# String comparison
if [ "$status" = "connected" ]; then
    echo "Connected"
fi

# Numeric comparison  
if [ "$exit_code" -ne 0 ]; then
    echo "Failed"
fi

# File tests
if [ -f "$config_file" ]; then
    echo "Config exists"
fi

# Negation
if [ ! -z "$variable" ]; then
    echo "Has value"
fi
```

### Loops

```bash
# Iterate over arguments
for pkg in "$@"; do
    brew install "$pkg"
done

# Iterate over command output
for file in $(find . -name "*.sh"); do
    echo "Found: $file"
done
```

### Case Statements

```bash
case "$1" in
    up)
        main_vpn_up
        ;;
    down)
        main_vpn_down
        ;;
    status)
        main_vpn_status
        ;;
    *)
        echo "Unknown command: $1"
        return 1
        ;;
esac
```

### Formatting Rules

- Use 4 spaces for indentation (or consistent with existing file)
- Empty line between function definitions
- Comments on their own line with `#`
- Maximum line length: ~100 characters (reasonable)

### Import/Dependency Management

- Source scripts at top of `simon` entry point
- External tools: `kubectl`, `talosctl`, `gh`, `git`, `brew`, `fzf`, `bw` (Bitwarden), `op` (1Password)
- Check tool availability before use: `command -v <tool>`

### CLI Patterns

```bash
# Interactive selection with fzf
fzfSelect() {
    local list=("$@")
    local selection
    selection=$(printf '%s\n' "${list[@]}" | fzf --multi)
    echo "$selection"
}

# Subcommand dispatching
case "$1" in
    install) shift; main_install "$@" ;;
    uninstall) shift; main_uninstall "$@" ;;
    *) echo "Unknown command: $1" ;;
esac
```

---

## Testing Strategy

1. **No Bash unit tests**: This project doesn't have dedicated shell script tests
2. **Manual verification**: Test CLI commands interactively
3. **Package.json tests**: Run `./simon test` to test projects in `$HOME/repos/`
4. **Infrastructure integration**: Use actual `kubectl`, `talosctl` commands to verify

---

## Git Conventions

- Branch naming: `feature/<description>`, `fix/<issue>`
- Commit messages: Descriptive, e.g., `feat: add new kubernetes command`
- Use `./simon commit` which runs tests, then `lazygit`, then opens Argo Workflows

---

## Key Files Reference

| File | Purpose |
|------|---------|
| `simon` | Main entry point, sources all scripts |
| `functions.sh` | Shared utilities like `fzfSelect()` |
| `scripts/*.sh` | Command implementations |
| `agent-os/` | Agent OS standards and workflows |
| `CRUSH.md` | Legacy documentation (outdated) |
