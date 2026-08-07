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
[`beryl_mist`](https://hex.pm/packages/beryl_mist):

```sh
gleam add beryl beryl_mist
```

beryl targets the **Erlang/BEAM** runtime only. It does not support the
JavaScript target.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl`)

## Writing a custom transport

The `beryl/transport` module is the public SPI for transport authors: socket
lifecycle announcements, inbound routing, codec access, and per-connection
rate limiting. `beryl_mist` is the reference implementation.

## Licence

MIT
