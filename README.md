# beryl

Type-safe real-time channels and presence for Gleam on the BEAM.

## Features

- **Channels** - Topic-based pub/sub with pattern matching (e.g., `room:*`)
- **Presence** - Distributed presence tracking using CRDTs (add-wins observed-remove set)
- **Groups** - Named channel groups for broadcast
- **PubSub** - pg-based process group messaging
- **WebSocket Transport** - Wisp integration for WebSocket connections

## Development

### Prerequisites

- [Erlang](https://www.erlang.org/) 27+
- [Gleam](https://gleam.run/) 1.1+
- [just](https://github.com/casey/just) (task runner)

Install tools via [mise](https://mise.jdx.dev/) or [asdf](https://asdf-vm.com/):

```sh
mise install
# or
asdf install
```

### Commands

```sh
just deps      # Download dependencies
just build     # Build the project
just test      # Run tests
just format    # Format code
just check     # Type check
just docs      # Build documentation
just ci        # Run all CI checks
```

### CI/CD

This project uses GitHub Actions for CI and automated releases:

- **CI**: Runs on every push/PR to main
- **PR Validation**: Checks PR title (commitlint) and changelog entries (changie)
- **Release**: Uses [changie](https://changie.dev/) for changelog-driven versioning
- **Publish**: Automatically publishes to [Hex.pm](https://hex.pm) on tag push

### GitHub Secrets Required

| Secret | Description |
|--------|-------------|
| `RELEASE_PAT` | GitHub PAT with `contents:write` and `pull-requests:write` permissions |
| `HEXPM_API_KEY` | API key from [hex.pm](https://hex.pm) for publishing |

### Commit Convention

This project uses [Conventional Commits](https://www.conventionalcommits.org/):

- `feat:` - New features (minor version bump)
- `fix:` - Bug fixes (patch version bump)
- `docs:` - Documentation changes
- `chore:` - Maintenance tasks
- `BREAKING CHANGE:` in commit body - Major version bump

## License

Apache-2.0 - see [LICENSE](LICENSE) for details.
