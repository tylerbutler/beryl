# beryl

Type-safe real-time channels and presence for Gleam on the BEAM.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready. We welcome
> usage and feedback in the meantime!

beryl is the core channels library: Phoenix-style channels with typed assigns,
topic pattern matching, broadcasts, CRDT-backed presence tracking, pg-based
PubSub for multi-node fan-out, and built-in abuse controls (rate limits,
connection ceilings, heartbeat eviction).

To serve channels over WebSockets, pair it with a transport package such as
`beryl_mist`. beryl is not yet on Hex, so add both as git dependencies in your
`gleam.toml`:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "v0.0", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "v0.0", path = "packages/beryl_mist" }
```

> [!IMPORTANT]
> **Gleam 1.18 or later is required.** These packages live in subdirectories of
> the beryl monorepo, and the `path` field for git dependencies was added in
> Gleam 1.18.

beryl targets the **Erlang/BEAM** runtime only. It does not support the
JavaScript target.

## Documentation

- Guides: <https://beryl.tylerbutler.com>
- API reference: <https://beryl.tylerbutler.com/reference/api/>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl`)

## Writing a custom transport

The `beryl/transport` module is the public SPI for transport authors: socket
lifecycle announcements, inbound routing, codec access, and per-connection
rate limiting. `beryl_mist` is the reference implementation; `beryl_ewe`
mirrors it against the same SPI.

## License

MIT
