---
title: Observability
description: Telemetry events, runtime snapshots, and application-owned metrics export.
---

Beryl provides two types of data:

- Optional `:telemetry` events report rates, outcomes, and operation durations.
- `beryl/stats.snapshot` reports local runtime state at one time.

Beryl does not include a Prometheus or OpenTelemetry exporter. Your application
must aggregate, label, and export the data.

## Enable telemetry

Telemetry is disabled by default:

```gleam
let config =
  beryl.config(wire.phoenix_codec())
  |> beryl.with_telemetry
```

Attach handlers before traffic begins. Erlang `:telemetry` invokes handlers
**synchronously in the process emitting the event**. A slow handler therefore
adds latency to a WebSocket connection process, a socket's runtime actor,
or the runtime's router.
Perform bounded counter/histogram updates or enqueue a small message and
return immediately; never make network calls, format logs, or run expensive
label conversion in the handler.

Event names and their measurement/metadata keys form Beryl's stable,
low-cardinality telemetry taxonomy:

| Event | Measurements | Metadata |
|---|---|---|
| `[:beryl, :transport, :upgrade, :stop]` | `count`, `duration` | `transport`, `outcome` |
| `[:beryl, :transport, :frame, :stop]` | `count`, `duration`, `bytes` | `transport`, `frame_type`, `outcome` |
| `[:beryl, :socket, :connected]` | `count` | none |
| `[:beryl, :socket, :disconnected]` | `count`, `duration`, `joined_channels` | `reason` |
| `[:beryl, :channel, :join, :stop]` | `count`, `duration` | `outcome` |
| `[:beryl, :channel, :message, :stop]` | `count`, `duration` | `kind`, `outcome`, `callback_result` |
| `[:beryl, :broadcast, :stop]` | `count`, `duration`, `recipients` | `origin` |

The `:channel` event-name segment is retained for telemetry compatibility
even though app-side dispatch now owns routing. For an app `update`,
`callback_result` describes the first response-like effect (`reply`,
`reply_error`, or `push`), `no_reply` when none is returned, and `stop` for a
socket stop.

`duration` uses the BEAM's native monotonic time unit. Convert it with
`erlang:convert_time_unit(Value, native, microsecond)` (or another desired
unit) before export. It is not milliseconds. Counts and byte/recipient fields
are integers.

Metadata values are atoms from closed vocabularies. They intentionally omit
topics, socket IDs, payloads, and arbitrary error text, so the built-in labels
remain bounded:

| Key | Values |
|---|---|
| `transport` | `mist`, `ewe` |
| upgrade `outcome` | `success`, `origin_rejected`, `version_rejected`, `auth_rejected`, `capacity_rejected`, `handshake_failed` |
| frame `outcome` | `routed`, `oversized`, `rate_limited`, `decode_failed` |
| join `outcome` | `accepted`, `handler_rejected`, `no_handler`, `invalid_topic`, `topic_limit`, `rate_limited`, `callback_error`, `socket_missing` |
| message `outcome` | `handled`, `unjoined`, `stale`, `invalid`, `rate_limited`, `callback_error`, `socket_missing` |
| `frame_type` | `text`, `binary` |
| message `kind` | `text`, `binary`, `info`, `heartbeat` |
| `callback_result` | `not_applicable`, `no_reply`, `reply`, `reply_error`, `push`, `stop`, `failed` |
| disconnect `reason` | `normal`, `heartbeat_timeout`, `shutdown`, `callback_error` |
| broadcast `origin` | `local`, `remote` |

Map future unknown values to an `"unknown"` label. Do not crash the handler.

## Export to Prometheus or Grafana

Keep the exporter at the application boundary:

1. Attach one handler with `telemetry:attach_many/4`.
2. Map each event to an application-owned counter or histogram. Preserve only
   the bounded metadata above as labels.
3. Convert native durations and update the in-memory aggregator synchronously,
   or send a bounded message to a supervised metrics actor.
4. Expose the aggregator through your existing Prometheus HTTP endpoint,
   OpenTelemetry SDK, or hosted metrics client.
5. Configure Prometheus to scrape that endpoint and use Grafana to query the
   resulting series.

For example, an application FFI module can attach a single Erlang handler:

```erlang
-module(my_app_beryl_metrics).
-export([attach/1, detach/1]).

attach(AggregatorPid) ->
    Id = {?MODULE, AggregatorPid},
    Events = [
        [beryl, transport, upgrade, stop],
        [beryl, transport, frame, stop],
        [beryl, socket, connected],
        [beryl, socket, disconnected],
        [beryl, channel, join, stop],
        [beryl, channel, message, stop],
        [beryl, broadcast, stop]
    ],
    telemetry:attach_many(
        Id,
        Events,
        fun(Event, Measurements, Metadata, Pid) ->
            %% Keep this non-blocking and bound the receiver's mailbox.
            Pid ! {beryl_metric, Event, Measurements, Metadata}
        end,
        AggregatorPid
    ),
    Id.

detach(Id) ->
    telemetry:detach(Id).
```

The supervised aggregator can convert messages for your metrics library.
Monitor its mailbox and use bounded aggregation or backpressure. Another
process prevents direct request latency, but an unbounded mailbox can still
overload the system. Detach the handler during shutdown. Beryl does not need an
exporter dependency.

Useful derived signals include upgrade rejection rate by outcome, frame decode
and rate-limit rates, join/message callback failures, connection lifetime,
broadcast recipient counts, and latency histograms. Alert on sustained rates
and tail latency rather than individual events.

## Runtime snapshots

`beryl/stats.snapshot(channels)` requests a point-in-time view from the
socket runtime represented by `channels`:

```gleam
import beryl/stats

case stats.snapshot(channels) {
  Ok(snapshot) -> {
    let sockets = stats.connected_sockets(snapshot)
    let joined_pairs = stats.joined_socket_topic_pairs(snapshot)
    let topics = stats.active_topics(snapshot)
    // Publish these gauges through the application's metrics system.
  }
  Error(stats.RuntimeUnavailable) -> {
    // Supervisor restart or shutdown: report the scrape/poll as unavailable.
  }
  Error(stats.RequestTimedOut) -> {
    // The bounded request was not serviced in approximately one second.
  }
}
```

The snapshot describes one socket runtime on one BEAM node. It is not a cluster
transaction or an event stream. Aggregate gauges across nodes in the monitoring
system. `joined_socket_topic_pairs` counts memberships. One socket on two
topics adds two. The runtime records counts when it handles the request, so
in-flight connection changes can appear later.

Poll no more than once per second. Each poll sends a request through the
runtime. Many synchronized scrapers can add load. Use one application poller
per node. Cache the latest successful snapshot, add jitter, and expose the
snapshot age. Do not convert a timeout to a zero-valued snapshot. A timeout can
mean restart or overload, not an idle system.

For a runnable JSON endpoint combining Beryl and BEAM runtime gauges, see the
benchmark server's [`/stats` reference](https://github.com/tylerbutler/beryl/blob/main/examples/load_test/README.md#health-and-stats)
and
[`http.gleam`](https://github.com/tylerbutler/beryl/blob/main/examples/load_test/src/load_test/http.gleam).
That endpoint polls on request and is a benchmark fixture, not a bundled
exporter. In production, prefer one application-owned poller per node and
serve its cached snapshot through your metrics handler.

## Capacity tests

Correlate telemetry and snapshots with BEAM process/port counts, memory, run
queue, host CPU, open file descriptors, TCP statistics, and proxy/NAT
utilization. The repository's [load-testing guide](https://github.com/tylerbutler/beryl/blob/main/load/README.md)
documents profiles, result metadata, repeatable baselines, and safe tuning.
