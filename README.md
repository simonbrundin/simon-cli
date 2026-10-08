# simon-cli

A personal CLI tool written in Bash for infrastructure management, development workflows, and system operations.

## Quick Start

```bash
./simon              # Run interactive CLI
./simon --help       # Show help
```

## Key Commands

- `simon dev` - Start Tilt dev environment (builds from local repo, uses template Tiltfile)
- `simon cluster` - Kubernetes cluster management
- `simon git` - Git operations
- `simon test` - Run tests for all package.json projects

See [AGENTS.md](AGENTS.md) for detailed documentation.