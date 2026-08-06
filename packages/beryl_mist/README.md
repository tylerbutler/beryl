# beryl_mist

[Mist](https://hex.pm/packages/mist) WebSocket transport for
[beryl](https://hex.pm/packages/beryl) real-time sockets.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

```sh
gleam add beryl beryl_mist
```

## Usage

```gleam
import beryl
import beryl/event.{type ConnectInfo, AcceptJoin, Join, Next}
import beryl/wire
import beryl_mist as mist_transport
import gleam/erlang/process
import gleam/option.{None}
import gleam/otp/static_supervisor
import mist

pub type Model {
  Model
}

fn init(_info: ConnectInfo(msg)) -> #(Model, List(event.Effect)) {
  #(Model, [])
}

fn update(model: Model, ev: event.Input(msg)) -> event.Next(Model, msg) {
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
      mist_transport.default_config("/socket"),
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
or allow-all), and enforces beryl's frame-size, message-rate, and connection
limits at the edge.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl_mist>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_mist`)

## Licence

MIT
