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
import beryl_mist as mist_transport
import mist

pub fn main() {
  let assert Ok(channels) = beryl.start(beryl.default_config())
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
