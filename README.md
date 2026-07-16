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
gleam add beryl beryl_mist
```

`beryl` is the core channels library; `beryl_mist` is the [Mist](https://hex.pm/packages/mist)
WebSocket transport. Both live in this repository (a [trellis](https://trellis.tylerbutler.com)-managed
workspace under `packages/`).

beryl targets the **Erlang/BEAM** runtime only. It does not support the JavaScript target.

## Quick start

```gleam
import beryl
import beryl/channel.{type Channel, type HandleResult, type JoinResult}
import beryl/socket.{type Socket}
import beryl_mist as mist_transport
import beryl/wire
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/option.{None}
import mist

pub type RoomAssigns { RoomAssigns(username: String) }

fn new_channel() -> Channel(RoomAssigns, info) {
  channel.new(fn(_topic, payload, socket) {
    let username_decoder = {
      use username <- decode.field("username", decode.string)
      decode.success(username)
    }
    let username = case channel.decode_payload(payload, username_decoder) {
      Ok(username) -> username
      Error(_) -> "anonymous"
    }
    channel.JoinOk(reply: None, socket: socket.set_assigns(socket, RoomAssigns(username:)))
  })
  |> channel.with_handle_in(fn(_event, _payload, socket) {
    channel.NoReply(socket)
  })
}

pub fn main() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", new_channel())

  let assert Ok(_) =
    mist_transport.handler(channels, mist_transport.default_config("/socket/websocket"), fn(_req) {
      // your regular HTTP handler here
      panic as "not implemented"
    })
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
```

`mist_transport.handler` composes the WebSocket upgrade and your HTTP handler
into a single Mist request handler: WebSocket upgrades on the configured path go
to beryl, everything else falls through to the HTTP fallback. If you need to drive
the upgrade decision yourself, `mist_transport.upgrade` (and the
`mist_transport.is_websocket_request` guard) remain available.

For a complete end-to-end walkthrough including Phoenix JS client code, see the
**[Quick Start guide](https://beryl.tylerbutler.com/quick-start/)** on the docs website.

## Documentation

- **Website & guides**: <https://beryl.tylerbutler.com>
- **Generated API docs**: <https://hexdocs.pm/beryl/>

## Ecosystem

Beryl is the server-side channel runtime. It owns socket registration, channel
handlers, broadcasts, presence, groups, pubsub, and transport integration.
Beryl has its own pluggable wire codec, and its Phoenix codec is kept compatible
with Roost and Aquamarine by shared conformance fixtures.

```mermaid
flowchart TD
    fixtures["phoenix_channel_fixtures\ncanonical wire test data"]
    roost["roost\nPhoenix channel wire protocol"]
    beryl["beryl\nserver runtime"]
    aquamarine["aquamarine\nclient runtime"]
    gluegun["gluegun\nclient WebSocket transport"]
    mist["mist\nserver WebSocket transport"]

    fixtures -. "test fixtures" .-> roost
    fixtures -. "test fixtures" .-> beryl
    fixtures -. "test fixtures" .-> aquamarine

    roost --> aquamarine
    mist --> beryl
    gluegun --> aquamarine

    aquamarine <-- "Phoenix channel wire" --> beryl
```

| Package | Responsibility |
|---------|----------------|
| `phoenix_channel_fixtures` | Shared test fixtures for Phoenix channel wire compatibility. |
| `roost` | Pure Phoenix channel frame constants, encode/decode helpers, and reply helpers. |
| `beryl` | Server-side runtime with its own pluggable codec; its Phoenix codec is fixture-tested. |
| `aquamarine` | Client-side channel runtime that uses Roost for Phoenix compatibility. |

## Features

- **Channels** — Topic-based pub/sub with typed callbacks and pattern matching (e.g. `room:*`, `document:*:*`)
- **Presence** — Distributed presence tracking using a CRDT (add-wins observed-remove set)
- **Groups** — Named channel groups for multi-topic broadcasting
- **PubSub** — pg-based distributed publish/subscribe
- **Actor bridge** — forward an external OTP actor's stream to a socket with `beryl/bridge`
- **WebSocket transport** — Mist integration with Phoenix-compatible wire protocol
- **Connect hook** — Socket-level `on_connect` authentication (Phoenix `UserSocket.connect/3` analogue): runs once per socket, can reject the whole connection before any join, and seeds initial assigns

## Examples

Three runnable demos are included in the `examples/` directory:

| Example | What it demonstrates |
|---------|----------------------|
| [`examples/cursors`](examples/cursors/) | Channels, topic wildcards, presence, `broadcast_from`, rate limiting |
| [`examples/chatrooms`](examples/chatrooms/) | Auth (`on_connect`), join rejection, `Reply`, `Push`, groups, validation, typing indicators |
| [`examples/collab_docs`](examples/collab_docs/) | Client-side CRDT document blocks, segment wildcards, conflict resolution |

See the [Examples page](https://beryl.tylerbutler.com/examples/) in the docs for a full comparison.

## Recipe: bridge an external actor to a socket

A long-lived domain actor (for example a per-document session) often emits
updates that need to be pushed to each joined socket. The `beryl/bridge` module
removes the per-socket forwarder boilerplate: start a bridge in `join`, subscribe
your actor to the bridge's `Subject`, and stop it in `terminate`. Each value the
actor emits is translated and delivered to the channel's `handle_info` callback
via `beryl.send_info`. The forwarder also monitors the channel process, so it is
cleaned up automatically if that process dies — no leaked processes.

```gleam
import beryl.{type RegisteredChannel}
import beryl/bridge.{type Bridge}
import beryl/channel.{type Channel}
import beryl/socket
import gleam/json
import gleam/option.{None}

// Messages emitted by your domain actor.
pub type DocEvent {
  Updated(version: Int)
}

pub type Assigns {
  Assigns(bridge: Bridge(DocEvent))
}

// `registered_channel` is the handle returned by `beryl.register`.
fn new_channel(
  registered_channel: RegisteredChannel(Assigns, DocEvent),
  doc_actor,
) -> Channel(Assigns, DocEvent) {
  channel.new(fn(topic, _payload, socket) {
    // Forward every DocEvent emitted by the actor to this socket/topic.
    let b =
      bridge.start(
        channel: registered_channel,
        socket_id: socket.id(socket),
        topic: topic,
        with: fn(event) { event },
      )
    // Hand the bridge's subject to the domain actor as its subscriber.
    doc.subscribe(doc_actor, bridge.subject(b))
    channel.JoinOk(reply: None, socket: socket.set_assigns(socket, Assigns(b)))
  })
  // `handle_info` receives the typed `DocEvent` directly — no decode step.
  |> channel.with_handle_info(fn(event, socket) {
    case event {
      Updated(version) ->
        channel.Push(
          "doc_updated",
          json.object([#("version", json.int(version))]),
          socket,
        )
    }
  })
  // Always stop the bridge on terminate for prompt, deterministic cleanup.
  |> channel.with_terminate(fn(_reason, socket) {
    bridge.stop(socket.get_assigns(socket).bridge)
  })
}
```

## Releases & changelog

See the [GitHub Releases](https://github.com/tylerbutler/beryl/releases) page for
release notes. Releases follow [Conventional Commits](https://www.conventionalcommits.org/)
and changelogs are managed with [trellis](https://trellis.tylerbutler.com) changelog fragments.

## Security

Beryl uses **Erlang distribution** for its distributed PubSub and presence
replication, which means **every node in your cluster is fully trusted**.
Application- and channel-level authorization protects you against untrusted
WebSocket clients; it does **not** protect you against a hostile Erlang
distribution peer, which can inject internal beryl traffic and presence state.

Before running beryl in production, read **[SECURITY.md](SECURITY.md)**, which
covers:

- The Erlang distribution **trust boundary** and what a compromised peer can do.
- Distribution hardening: a strong protected cookie, TLS distribution, EPMD/port
  firewalling, and keeping cluster membership closed.
- Why internal PubSub/presence messages are trusted while client WebSocket
  messages are validated and rate-limited.
- The `pubsub.config_with_scope` atom-table constraint (never pass it
  user-derived values).

For client-facing abuse controls (rate limits, connection caps, origin checks),
see the [Production Hardening guide](https://beryl.tylerbutler.com/guides/production-hardening/).

## Development

### Prerequisites

- [Erlang](https://www.erlang.org/) 27+
- [Gleam](https://gleam.run/) 1.13+
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
- **PR Validation**: Checks PR title (commitlint), workspace invariants (`trellis doctor`), and changelog fragments (`trellis changelog check`)
- **Release**: [trellis](https://trellis.tylerbutler.com) maintains a release PR from unreleased changelog fragments
- **Publish**: Merging the release PR publishes each package to [Hex.pm](https://hex.pm) in dependency order and creates per-package tags

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
