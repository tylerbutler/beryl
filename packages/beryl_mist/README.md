# beryl_mist

[Mist](https://hex.pm/packages/mist) WebSocket transport for
[beryl](https://github.com/tylerbutler/beryl/tree/main/packages/beryl)
real-time sockets.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

## Overview

The adapter exposes Mist request handlers and delegates shared admission,
configuration, and frame policy to beryl's public transport server
(`src/beryl_mist.gleam:upgrade`, `src/beryl_mist.gleam:handler`).

## Interface

- `upgrade(request, channels, config, next)` attempts a WebSocket upgrade
  (`src/beryl_mist.gleam:upgrade`).
- `handler(channels, config, http_fallback)` combines WebSocket and HTTP
  handling (`src/beryl_mist.gleam:handler`).
- Callers use the imported `beryl/transport/server.TransportConfig`.
  [Source contract](./src/README.md) describes Mist callbacks and lifecycle.
- Runtime dependencies include beryl, Mist, and glisten
  (`gleam.toml:dependencies`).

## Invariants

- Upgrade/fallback routing and frame handling delegate to the shared server.
  Connection initialization uses its configured codec
  (`src/beryl_mist.gleam:handler`, `src/beryl_mist.gleam:do_upgrade`,
  `src/beryl_mist.gleam:on_message`).
- `Closed`, `Shutdown`, and server close requests stop the connection; outbound
  send results pass through shared write accounting
  (`src/beryl_mist.gleam:on_message`).

## Side effects

Mist manages WebSocket lifecycle and writes frames. Shared server calls
admit/register/route/clean up the connection. Force-close closes the glisten
transport; an already-closed or not-connected result counts as success
(`src/beryl_mist.gleam:do_upgrade`, `src/beryl_mist.gleam:on_message`,
`src/beryl_mist.gleam:force_close`).

## Verification

From the repository root: `just test beryl_mist`.

## Installation

beryl packages are currently distributed from GitHub, not Hex:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
```

Use the same git ref for beryl and beryl_mist.
See the [installation guide](https://beryl.tylerbutler.com/installation/) for
release-tag guidance.

## Usage

```gleam
import beryl
import beryl/socket.{type ConnectInfo, AcceptJoin, Join, Next}
import beryl/wire
import beryl/transport/server
import beryl_mist as mist_transport
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import mist

pub type Model {
  Model
}

fn init(_info: ConnectInfo(msg)) -> #(Model, List(socket.Effect)) {
  #(Model, [])
}

fn update(model: Model, ev: socket.Input(msg)) -> socket.Next(Model) {
  case ev {
    Join("room:" <> _, _payload, ref) -> Next(model, [AcceptJoin(ref, None)])
    _ -> Next(model, [])
  }
}

pub fn main() {
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(beryl.config(wire.phoenix_codec()), init:, update:)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()

  let assert Ok(_) =
    mist_transport.handler(
      sockets,
      server.default_config("/socket"),
      fn(_req) { panic as "not implemented" },
    )
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
```

The transport serves WebSocket upgrades and regular HTTP from a single Mist
listener, runs an optional `on_connect` authentication hook before the
upgrade, validates the `Origin` header (same-origin by default, allow-list,
or allow-all), and enforces beryl's frame-size, frame-rate, and connection
limits at the edge.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package API: <https://beryl.tylerbutler.com/reference/api/beryl_mist/>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_mist`)

## Licence

MIT
