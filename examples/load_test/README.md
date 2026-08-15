# Beryl benchmark server

This headless application is the target for the repository's Phoenix V2
[k6 load suite](../../load/README.md). It exposes the same channel contract
through Mist and Ewe so transport runs are comparable.

## Prerequisites

For a source run, install the repository versions (Erlang 27.2.1, Gleam
1.16.0, and just 1.50.0), plus `rebar3`, `trellis`, and `pnpm`, then run
`just deps` from the repository root. Docker is required for the image and
for the pinned k6 commands in the load guide.

## Run from source

From the repository root, choose one transport:

```sh
just load-server-mist
just load-server-ewe
```

The equivalent direct commands are:

```sh
cd examples/load_test
gleam run -m load_test_mist
gleam run -m load_test_ewe
```

Both servers bind to `127.0.0.1:8000` by default. They provide:

| Route | Behavior |
|---|---|
| `/health` | `200`, `content-type: application/json`, `{"status":"ok"}` |
| `/stats` | Local Beryl socket runtime and BEAM runtime JSON described below |
| WebSocket `/socket` | Phoenix V2 benchmark channels |
| Any other route | `404` with an empty body |

The handlers route by path and do not inspect the HTTP method.

The WebSocket route accepts `bench:*`. `echo` replies with the unchanged
payload; `broadcast` and `broadcast_ack` broadcast and reply with the unchanged
payload; `presence_track` and `presence_untrack` update the example's
nonblocking session tracker and reply with the key. Changes are broadcast as
`presence_list` snapshots.
`guardrail:forbidden` always rejects a join with `{"reason":"forbidden"}`.
Unknown inbound events return `{"reason":"unknown_event"}`.

## Environment

Missing integer variables and values that `gleam/int.parse` cannot parse use
the listed default. The application does not otherwise range-check them before
passing them to Beryl; invalid heartbeat values can prevent the supervised
server from starting. Rate and connection values at or below zero disable
their limit. All heartbeat durations are milliseconds, all rates are events
per second, and string limits are bytes.

For each enabled rate limit, a burst of `0` defaults to the corresponding
per-second rate. A positive burst sets an explicit bucket capacity. A negative
burst is accepted as configured but provides no usable capacity, so every
event is rate-limited; use `0` for the default instead. If the corresponding
rate is non-positive, the limit is disabled regardless of its burst value.

| Variable | Default | Meaning |
|---|---:|---|
| `BIND_ADDRESS` | `127.0.0.1` | Listener interface |
| `PORT` | `8000` | Listener TCP port |
| `SERVER` | Mist | `ewe` selects Ewe in the shipment entry point; every other value selects Mist |
| `BERYL_HEARTBEAT_TIMEOUT_MS` | `60000` | Server staleness/eviction window, in ms |
| `BERYL_MAX_CONNECTIONS_PER_IP` | `0` | Concurrent connections per real peer IP; `<= 0` is unlimited |
| `BERYL_MAX_CONNECTIONS` | `0` | Concurrent connections on this BEAM node; `<= 0` is unlimited |
| `BERYL_FRAME_RATE` | `0` | Per-connection inbound frame rate before decoding; `<= 0` disables it |
| `BERYL_FRAME_BURST` | `0` | Frame bucket capacity; `0` defaults to `BERYL_FRAME_RATE` |
| `BERYL_MESSAGE_RATE` | `0` | Per-socket message rate; `<= 0` disables it |
| `BERYL_MESSAGE_BURST` | `0` | Message bucket capacity; `0` defaults to `BERYL_MESSAGE_RATE` |
| `BERYL_JOIN_RATE` | `0` | Per-socket join rate; `<= 0` disables it |
| `BERYL_JOIN_BURST` | `0` | Join bucket capacity; `0` defaults to `BERYL_JOIN_RATE` |
| `BERYL_CHANNEL_RATE` | `0` | Per-socket, per-topic message rate; `<= 0` disables it |
| `BERYL_CHANNEL_BURST` | `0` | Channel bucket capacity; `0` defaults to `BERYL_CHANNEL_RATE` |
| `BERYL_CHANNEL_RATE_MAX_KEYS_PER_SOCKET` | `1000` | Active per-channel rate buckets per socket; `<= 0` removes this cap |
| `BERYL_MAX_TOPIC_LENGTH` | `256` | Maximum client topic length in bytes |
| `BERYL_MAX_EVENT_LENGTH` | `64` | Maximum client event-name length in bytes |
| `BERYL_MAX_INBOUND_FRAME_BYTES` | `1048576` | Maximum assembled inbound frame size in bytes (1 MiB) |
| `BERYL_MAX_JOINED_TOPICS_PER_SOCKET` | `1000` | Maximum simultaneous joined topics per socket |
| `BERYL_TELEMETRY` | `false` | Enables Beryl telemetry for `1`, `true`, `yes`, or `on`, case-insensitively |

If `BERYL_TELEMETRY` is missing it is false; any value not in the four-value
true set is also false. Enabling it only emits events. This fixture does not
attach a telemetry handler or exporter, so it does not persist or expose those
events by itself. Handlers run synchronously and can distort a benchmark if
they block or do substantial work.

## Health and stats

`/health` reports that the HTTP server can answer; it does not query the
socket runtime or dependencies.

A successful `/stats` response is:

```json
{
  "beryl": {
    "connected_sockets": 0,
    "joined_socket_topic_pairs": 0,
    "active_topics": 0,
    "runtime_mailbox_length": 0
  },
  "beam": {
    "process_count": 0,
    "port_count": 0,
    "memory_bytes": 0,
    "run_queue": 0,
    "schedulers_online": 0,
    "runtime_version": "27"
  }
}
```

The numbers above illustrate the JSON shape, not expected values.
`runtime_version` is `erlang:system_info(otp_release)`. The endpoint returns:

| Status | Body | Cause |
|---:|---|---|
| `200` | Object shown above | Both snapshots succeeded |
| `503` | `{"error":"runtime_unavailable"}` | Beryl socket runtime unavailable |
| `503` | `{"error":"runtime_stats_unavailable"}` | BEAM snapshot FFI failed |
| `504` | `{"error":"runtime_timeout"}` | Socket runtime snapshot request timed out |

Snapshots are local to one socket runtime and one BEAM node. Poll no more often
than roughly once per second; under load, a `504` is a signal rather than a
zero-valued sample.

## Docker and Erlang shipment

Build from the repository root because the example uses workspace path
dependencies:

```sh
just load-server-docker mist beryl-load-test:mist
just load-server-docker ewe beryl-load-test:ewe

docker run --rm -p 8000:8000 beryl-load-test:mist
curl --fail http://127.0.0.1:8000/health
```

To build and run the shipment without Docker:

```sh
cd examples/load_test
gleam export erlang-shipment
SERVER=ewe BIND_ADDRESS=127.0.0.1 PORT=8000 \
  ./build/erlang-shipment/entrypoint.sh run
```

`load-server-docker` passes `SERVER` as a build argument. The Dockerfile
defaults `SERVER=mist`, rejects build values other than `mist` or `ewe`,
exports a production Erlang shipment, and copies that shipment into the final
image. The final image sets `BIND_ADDRESS=0.0.0.0`, `PORT=8000`, and `SERVER`
to the build value. Runtime `-e` values may override them; `SERVER=ewe`
selects Ewe and every other runtime value selects Mist:

```sh
docker run --rm -p 9000:9000 \
  -e SERVER=ewe -e BIND_ADDRESS=0.0.0.0 -e PORT=9000 \
  -e BERYL_TELEMETRY=true -e BERYL_MAX_CONNECTIONS=10000 \
  beryl-load-test:mist
```

The generated `entrypoint.sh run` starts `load_test` with `erl -noshell`;
`shell` starts an Erlang shell.

The two stages use `erlang:27.2.1-alpine`. `GLEAM_VERSION` is a build argument
with default `v1.16.0`; the build downloads the matching musl archive for
`aarch64` or `x86_64`. For reproducible benchmark records, retain the image
digest and built image ID as well as these version values: the base image is
tag-pinned, not digest-pinned, and the downloaded Gleam archive is not checked
against a checksum in the Dockerfile.

The image exposes port 8000 but defines no Docker `HEALTHCHECK`; use `/health`
from the orchestrator. Server logs go to container stdout/stderr. k6 results
and summaries are produced by the separate load-generator container and are
not written by this server image; mount or retain `load/results` on the
generator as described in the [load guide](../../load/README.md).
