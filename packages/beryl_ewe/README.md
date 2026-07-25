# beryl_ewe

[Ewe](https://hex.pm/packages/ewe) WebSocket transport for
[beryl](https://hex.pm/packages/beryl) real-time sockets.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

```sh
gleam add beryl beryl_ewe
```

## Usage

```gleam
import beryl
import beryl/event.{type ConnectInfo, AcceptJoin, Join, Next}
import beryl/wire
import beryl/transport/server
import beryl_ewe as ewe_transport
import ewe
import gleam/erlang/process
import gleam/option.{None}

pub type Model {
  Model
}

fn init(_info: ConnectInfo(msg)) -> #(Model, List(event.Effect)) {
  #(Model, [])
}

fn update(model: Model, ev: event.Event(msg)) -> event.Next(Model, msg) {
  case ev {
    Join("room:" <> _, _payload, ref) -> Next(model, [AcceptJoin(ref, None)])
    _ -> Next(model, [])
  }
}

pub fn main() {
  let assert Ok(sockets) =
    beryl.start(beryl.config(wire.phoenix_codec()), init:, update:)

  let assert Ok(_) =
    ewe_transport.handler(
      sockets,
      server.default_config("/socket"),
      fn(_req) { panic as "not implemented" },
    )
    |> ewe.new
    |> ewe.listening(port: 8000)
    |> ewe.start

  process.sleep_forever()
}
```

The transport serves WebSocket upgrades and regular HTTP from a single Ewe
listener, runs an optional `on_connect` authentication hook before the
upgrade, validates the `Origin` header (same-origin by default, allow-list,
or allow-all), and enforces beryl's frame-size, message-rate, and connection
limits at the edge.

It mirrors the [`beryl_mist`](https://hex.pm/packages/beryl_mist) package: both
transports expose the same config-builder and handler API, so you can run beryl
sockets on either web server by choosing the matching transport package.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl_ewe>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_ewe`)

## Licence

MIT
