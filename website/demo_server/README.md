# Beryl documentation demo service

This package holds the realtime scenario embedded in the beryl documentation:
a validated `demo:presence:*` channel with absolute scenario expiry, plus the
`/v1/status` endpoint the site queries. Every client is untrusted, joins only
randomized topics, and receives no access to application data.

In production the channel is not a separate service: `examples/showcase`
registers `beryl_demo/presence_channel` on its own socket and serves
`/v1/status`, and the documentation site connects to
`https://demo.beryl.tylerbutler.com`. The standalone server in
`beryl_demo/server` exists for local development and the Playwright e2e
suite, and its integration tests exercise the channel end to end.

## Run locally

```bash
PORT=4100 \
BIND_ADDRESS=127.0.0.1 \
ALLOWED_ORIGINS=http://127.0.0.1:4321 \
BERYL_VERSION=development \
gleam run
```

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `4100` | HTTP and WebSocket listener port |
| `BIND_ADDRESS` | `127.0.0.1` | Listener interface |
| `ALLOWED_ORIGINS` | Documentation and local origins | Comma-separated exact WebSocket Origin allow-list |
| `BERYL_VERSION` | `development` | Version reported by `/v1/status` |

Production must set:

```text
ALLOWED_ORIGINS=https://beryl.tylerbutler.com
```

## Health and compatibility

```bash
curl --fail http://127.0.0.1:4100/healthz
curl --fail http://127.0.0.1:4100/v1/status
```

`/v1/status` returns:

```json
{
  "status": "ok",
  "compatibility_version": 1,
  "beryl_version": "0.1.0",
  "scenarios": ["presence-v1"]
}
```

The service holds no persistent data. Presence state (name, client ID, and
color metadata) is kept in memory only; it is removed when the owning socket
disconnects. Scenarios have a fixed 10-minute absolute TTL: when a scenario
expires the service disconnects all connected clients and rejects rejoins for
that scenario ID.
