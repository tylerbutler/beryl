<table><tr>
<td><img src="website/src/assets/beryl.webp" alt="beryl logo" width="128"></td>
<td><h1>beryl</h1>Type-safe real-time channels and presence for Gleam on the BEAM.</td>
</tr></table>

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready. We welcome
> usage and feedback in the meantime!

## Install

```sh
gleam add beryl
```

beryl targets the **Erlang/BEAM** runtime only. It does not support the JavaScript target.

## Quick start

```gleam
import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import beryl/transport/mist as mist_transport
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import mist

pub type RoomAssigns { RoomAssigns(username: String) }

fn new_channel() -> Channel(RoomAssigns) {
  channel.new(fn(_topic, payload, socket) {
    let username = // ... extract from payload
    channel.JoinOk(reply: None, socket: socket.set_assigns(socket, RoomAssigns(username:)))
  })
  |> channel.with_handle_in(fn(_event, _payload, socket) {
    channel.NoReply(socket)
  })
}

pub fn main() {
  let assert Ok(channels) = beryl.start(beryl.default_config())
  let assert Ok(_) = beryl.register(channels, "room:*", new_channel())

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(req, channels.coordinator,
        mist_transport.default_config("/socket/websocket"), fn() {
          // your regular HTTP handler here
          panic as "not implemented"
        })
    }
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
```

For a complete end-to-end walkthrough including Phoenix JS client code, see the
**[Quick Start guide](https://beryl.tylerbutler.com/quick-start/)** on the docs website.

## Documentation

- **Website & guides**: <https://beryl.tylerbutler.com>
- **Generated API docs**: <https://hexdocs.pm/beryl/>

## Features

- **Channels** — Topic-based pub/sub with typed callbacks and pattern matching (e.g. `room:*`, `document:*:*`)
- **Presence** — Distributed presence tracking using a CRDT (add-wins observed-remove set)
- **Groups** — Named channel groups for multi-topic broadcasting
- **PubSub** — pg-based distributed publish/subscribe
- **WebSocket transport** — Mist integration with Phoenix-compatible wire protocol

## Examples

Three runnable demos are included in the `examples/` directory:

| Example | What it demonstrates |
|---------|----------------------|
| [`examples/cursors`](examples/cursors/) | Channels, topic wildcards, presence, `broadcast_from`, rate limiting |
| [`examples/chatrooms`](examples/chatrooms/) | Auth (`on_connect`), join rejection, `Reply`, `Push`, groups, validation, typing indicators |
| [`examples/collab_docs`](examples/collab_docs/) | Client-side CRDT document blocks, segment wildcards, conflict resolution |

See the [Examples page](https://beryl.tylerbutler.com/examples/) in the docs for a full comparison.

## Releases & changelog

See [CHANGELOG.md](CHANGELOG.md) for release notes. Releases follow
[Conventional Commits](https://www.conventionalcommits.org/) and are managed
with [changie](https://changie.dev/).

## Development

### Prerequisites

- [Erlang](https://www.erlang.org/) 27+
- [Gleam](https://gleam.run/) 1.3+
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

MIT — see [LICENSE](LICENSE) for details.
