# Beryl documentation demo service

This service runs the public realtime scenarios embedded in the beryl
documentation. It is intentionally separate from the static site: every client
is untrusted, joins only randomized `demo:presence:*` topics, and receives no
access to application data.

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

## Container

Build from the repository root because the nested project uses the root beryl
package as a path dependency:

```bash
docker build -f website/demo_server/Dockerfile -t beryl-demo .
docker run --rm \
  -p 4100:4100 \
  -e ALLOWED_ORIGINS=https://beryl.tylerbutler.com \
  -e BERYL_VERSION=0.1.0 \
  beryl-demo
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

The service stores no user data. Presence state is ephemeral and is removed when
the owning socket disconnects.
