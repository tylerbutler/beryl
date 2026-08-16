# beryl

Type-safe app-side real-time sockets and presence for Gleam on the BEAM.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready. We welcome
> usage and feedback in the meantime!

beryl is the core real-time library: app-side dispatch (one `init`/`update`
pair per app, Phoenix-compatible wire protocol), topic pattern matching,
broadcasts, CRDT-backed presence tracking, pg-based PubSub for multi-node
fan-out, and built-in abuse controls (rate limits, connection ceilings,
heartbeat eviction).

To serve sockets over WebSockets, pair it with a transport package such as
[`beryl_mist`](https://github.com/tylerbutler/beryl/tree/main/packages/beryl_mist).
Beryl packages are currently distributed from GitHub, not Hex:

```toml
[dependencies]
beryl = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl" }
beryl_mist = { git = "https://github.com/tylerbutler/beryl.git", ref = "main", path = "packages/beryl_mist" }
```

Use the same git ref for beryl and your transport package. See the
[installation guide](https://beryl.tylerbutler.com/installation/) for Ewe,
channel-layer, and release-tag guidance.

beryl targets the **Erlang/BEAM** runtime only. It does not support the
JavaScript target.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package API: <https://beryl.tylerbutler.com/reference/api/beryl/>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl`)

## Writing a custom transport

The `beryl/transport` module is the public SPI for transport authors: socket
lifecycle announcements, inbound routing, codec access, and per-connection
rate limiting. `beryl_mist` is the reference implementation.

## Licence

MIT
