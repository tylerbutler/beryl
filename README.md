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

## License

Apache-2.0 - see [LICENSE](LICENSE) for details.
