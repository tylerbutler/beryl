# beryl_ewe

[Ewe](https://hex.pm/packages/ewe) WebSocket transport for
[beryl](https://hex.pm/packages/beryl) real-time channels.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

```sh
gleam add beryl beryl_ewe
```

## Usage

```gleam
import beryl
import beryl_ewe as ewe_transport
import ewe

pub fn main() {
  let assert Ok(channels) = beryl.start(beryl.default_config())
  // register channels...

  let assert Ok(_) =
    ewe_transport.handler(
      channels,
      ewe_transport.default_config("/socket"),
      http_fallback,
    )
    |> ewe.new
    |> ewe.listening(port: 8000)
    |> ewe.start
}
```

The transport serves WebSocket upgrades and regular HTTP from a single Ewe
listener, runs an optional `on_connect` authentication hook before the
upgrade, validates the `Origin` header (same-origin by default, allow-list,
or allow-all), and enforces beryl's frame-size, message-rate, and connection
limits at the edge.

It mirrors the [`beryl_mist`](https://hex.pm/packages/beryl_mist) package: both
transports expose the same config-builder and handler API, so you can run beryl
channels on either web server by choosing the matching transport package.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl_ewe>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_ewe`)

## Licence

MIT
