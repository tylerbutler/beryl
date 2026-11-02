# beryl_ewe

[Ewe](https://hex.pm/packages/ewe) WebSocket transport for
[beryl](https://github.com/tylerbutler/beryl/tree/main/packages/beryl)
real-time sockets.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

## Overview

The adapter exposes Ewe request handlers and delegates shared admission,
configuration, and frame policy to beryl's public transport server
(`src/beryl_ewe.gleam:upgrade`, `src/beryl_ewe.gleam:handler`).

## Interface

- `upgrade(request, channels, config, next)` attempts a WebSocket upgrade
  (`src/beryl_ewe.gleam:upgrade`).
- `handler(channels, config, http_fallback)` combines WebSocket and HTTP
  handling (`src/beryl_ewe.gleam:handler`).
- Configuration uses the imported `beryl/transport/server.TransportConfig`.
  [Source contract](./src/README.md) describes the Ewe callbacks and lifecycle.
- The manifest declares runtime dependencies on beryl and Ewe; this package
  does not implement the shared server policy (`gleam.toml:dependencies`,
  `src/beryl_ewe.gleam:upgrade`).

## Invariants

- CONNECT without Host gets a header from request host/port. CONNECT and
  recognized WebSocket requests use upgrade; other requests use the fallback
  (`src/beryl_ewe.gleam:upgrade`, `src/beryl_ewe.gleam:handler`).
- Inbound frames and outbound write completion pass through shared server
  lifecycle functions (`src/beryl_ewe.gleam:on_message`).

## Side effects

Ewe manages the WebSocket lifecycle and writes text/binary frames. Shared server
calls admit/register/route/clean up the connection; force-close kills its owner
process (`src/beryl_ewe.gleam:do_upgrade`, `src/beryl_ewe.gleam:on_message`,
`src/beryl_ewe.gleam:force_close`).

## Verification

From the repository root: `just test beryl_ewe`.

## Installation

beryl packages are currently distributed from GitHub, not Hex:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_ewe = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_ewe" }
```

Use the same git ref for beryl and beryl_ewe.
See the [installation guide](https://beryl.tylerbutler.com/installation/) for
release-tag guidance.

## Usage

```gleam
import beryl
import beryl/socket.{type ConnectInfo, AcceptJoin, Join, Next}
import beryl/wire
import beryl/transport/server
import beryl_ewe as ewe_transport
import ewe
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor

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
    ewe_transport.handler(
      sockets,
      server.default_config("/socket"),
      fn(_req) { panic as "not implemented" },
    )
    |> ewe.new
    |> ewe.listening(on: 8000)
    |> ewe.start

  process.sleep_forever()
}
```

The transport serves WebSocket upgrades and regular HTTP from a single Ewe
listener, runs an optional `on_connect` authentication hook before the
upgrade, validates the `Origin` header (same-origin by default, allow-list,
or allow-all), and enforces beryl's frame-size, frame-rate, and connection
limits at the edge.

It mirrors the
[`beryl_mist`](https://github.com/tylerbutler/beryl/tree/main/packages/beryl_mist)
package: both use the shared transport-server config builders and matching
handler APIs, so you can run beryl sockets on either web server by choosing the
matching transport package.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package API: <https://beryl.tylerbutler.com/reference/api/beryl_ewe/>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_ewe`)

## Licence

MIT
