# beryl_mist

[Mist](https://hex.pm/packages/mist) WebSocket transport for
[beryl](https://hex.pm/packages/beryl) real-time channels.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

```sh
gleam add beryl beryl_mist
```

## Usage

```gleam
import beryl
import beryl/supervisor
import beryl/wire
import beryl_mist as mist_transport
import gleam/otp/static_supervisor
import mist

pub fn main() {
  // beryl doesn't start an unmanaged process; add its child specification to
  // your own application supervisor.
  let beryl_config = supervisor.config(beryl.config(wire.phoenix_codec()))

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(supervisor.start(beryl_config))
    |> static_supervisor.start()

  let channels = supervisor.channels(beryl_config)
  // register channels...

  let assert Ok(_) =
    mist_transport.handler(
      channels,
      mist_transport.default_config("/socket"),
      http_fallback,
    )
    |> mist.new
    |> mist.port(8000)
    |> mist.start
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
