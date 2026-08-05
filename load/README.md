# Load testing

The load suite uses the single k6 entry point `load/k6/run.js` and the
headless [benchmark server](../examples/load_test/README.md). The same Phoenix
V2 client and profiles target Mist or Ewe. Run target and generators on
separate hosts for capacity measurements; local runs validate the protocol,
not capacity.

## Local setup

Install Erlang 27+, Gleam 1.16+, `rebar3`, `just`, `trellis`, `pnpm`,
Node.js 22, and Docker. Then, from the repository root:

```sh
just deps
just load-check

# Terminal 1: choose one
just load-server-mist
just load-server-ewe

# Terminal 2
just load-run protocol-smoke ws://127.0.0.1:8000/socket mist
```

The servers default to `127.0.0.1:8000`, with WebSockets at `/socket` and JSON
at `/health` and `/stats`. For `mixed-ws-http`, also set
`HTTP_TARGET_URL=http://127.0.0.1:8000/health`. `just load-check [profile]`
runs Node syntax and helper/profile/lifecycle checks, then uses the pinned
`grafana/k6:2.1.0` image to inspect the selected profile without contacting a
server.

`load-run` uses Docker host networking. That reaches a host-bound
`127.0.0.1:8000` directly on Linux. On Docker Desktop, enable host networking
if the installed version supports it; otherwise run k6 natively or target a
server address reachable from the container instead of host loopback. Remote
targets work on every platform. A local port-8000 conflict can be avoided by
starting the server with `PORT=8001` and changing both target URLs.

## Exact profiles

All checked-in thresholds enforce correctness and unexpected-error behavior;
none gate latency or throughput percentiles.

| Profile | Executor and defaults | Workload |
|---|---|---|
| `protocol-smoke` | `per-vu-iterations`: 1 VU × 1 iteration, 30 s maximum | Connect, join `bench:smoke`, echo and verify a marker, then leave and close |
| `idle-connections` | `constant-vus`: 10 VUs for 1 m, 15 s graceful stop; sessions last 61,000 ms | Join `bench:idle`, remain open, and service heartbeats |
| `connection-rate` | `constant-arrival-rate`: 10 iterations/s for 1 m, 20 preallocated VUs, 100 maximum, 15 s graceful stop | Open and cleanly close a connection without joining |
| `push-round-trip` | `constant-vus`: 10 VUs for 1 m, 15 s graceful stop | Join `bench:reply`; send `echo` every 250 ms for 10,000 ms and verify the marker reply |
| `broadcast-fanout` | `constant-vus`: 10 VUs for 1 m, 15 s graceful stop | Groups of 5 join generated `bench:broadcast:*` topics; after 2,000 ms warmup, each publisher requires acknowledgements from 4 peers within 5,000 ms |
| `presence-churn` | `constant-vus`: 10 VUs for 1 m, 15 s graceful stop | Join `bench:presence`; track and untrack every 250 ms for 10,000 ms and require matching `presence_diff` joins/leaves within 5,000 ms |
| `mixed-ws-http` | `constant-vus`: 10 VUs for 1 m, 15 s graceful stop | Join `bench:mixed`; pair each 250 ms echo/reply with `GET HTTP_TARGET_URL` for 10,000 ms |
| `guardrail-validation` | `constant-vus`: 1 VU for 30 s, 10 s graceful stop | Repeatedly require `guardrail:forbidden` to reject the join with reason `forbidden`; expected join errors are not counted as unexpected |

All profiles require `TARGET_URL` or `TARGET_URLS`; the target may already
include `/socket`, or `WS_PATH=/socket` may append it, but not both. The
profile-specific inputs and primary signals are:

| Profile | Required and useful optional inputs | Primary metrics |
|---|---|---|
| `protocol-smoke` | Optional `TOPIC`, `EVENT` | `checks`, scenario-operation rate, establish/join/push/leave latency and failures |
| `idle-connections` | Optional `TOPIC`, `SESSION_DURATION_MS`, heartbeat settings | checks, opened/closed sessions, heartbeat replies/timeouts |
| `connection-rate` | Optional `RATE`, `PREALLOCATED_VUS`, `MAX_VUS`, `DURATION` | WebSocket failure and establishment latency, sessions opened/closed, `dropped_iterations` |
| `push-round-trip` | Optional `TOPIC`, `EVENT`, session/operation timing | push reply latency/timeouts and scenario-operation rate |
| `broadcast-fanout` | Optional broadcast topic/events, group/recipient counts, warmup, delivery/session timing | broadcast delivery rate/latency, push timeouts, scenario-operation rate |
| `presence-churn` | Optional `TOPIC`, presence events, delivery/session timing | presence delivery rate/latency and scenario-operation rate |
| `mixed-ws-http` | **Required** `HTTP_TARGET_URL`; optional `TOPIC`, `EVENT`, session/operation timing | push reply latency, `http_req_duration`, `http_req_failed`, scenario-operation rate |
| `guardrail-validation` | Optional `GUARDRAIL_TOPIC` | checks, expected join-rejection rate, join timeout, unexpected client errors |

Every profile requires `checks` and `phoenix_scenario_operation_rate` to equal
1, and requires zero unexpected client, protocol, decode, and WebSocket
failures. Every profile except `guardrail-validation` also requires zero
`phoenix_client_errors`; that profile deliberately produces a rejected join.
Additional zero-rate checks are:

- smoke: join rejection, join timeout, and push timeout;
- idle: join rejection and heartbeat timeout;
- push, broadcast, presence, and mixed: join rejection and push timeout;
- guardrail: join timeout.

Broadcast and presence additionally require their delivery rates to equal 1.
Mixed requires k6's `http_req_failed` rate to equal zero. Connection-rate has
no additional threshold.

`VUS` overrides VUs for constant-VU and per-VU profiles. `DURATION` overrides
profiles that have a duration. `RATE`, `PREALLOCATED_VUS`, and `MAX_VUS`
override the arrival-rate profile; `MAX_VUS` must be at least
`PREALLOCATED_VUS`. Positive-integer validation applies where used. The idle
profile accepts `DURATION` only as an integer followed by `ms`, `s`, `m`, or
`h` (for example, `90s` or `2m`).

### Workload and client settings

Profile parameters supply the defaults shown above. Environment variables
override them:

- `TOPIC`, `EVENT`, `SESSION_DURATION_MS`, `OPERATION_INTERVAL_MS`, and
  `DELIVERY_TIMEOUT_MS`;
- `BROADCAST_TOPIC`, `BROADCAST_EVENT`, `BROADCAST_DELIVERY_EVENT`,
  `BROADCAST_ACK_EVENT`, `BROADCAST_GROUP_SIZE`,
  `BROADCAST_EXPECTED_RECIPIENTS`, and `BROADCAST_WARMUP_MS`;
- `PRESENCE_TRACK_EVENT`, `PRESENCE_UNTRACK_EVENT`,
  `PRESENCE_DELIVERY_EVENT`, `GUARDRAIL_TOPIC`, and `HTTP_TARGET_URL`;
- `CONNECT_TIMEOUT_MS` (10,000), `REPLY_TIMEOUT_MS` (5,000),
  `LEAVE_TIMEOUT_MS` (2,000), `HEARTBEAT_INTERVAL_MS` (30,000),
  `HEARTBEAT_TIMEOUT_MS` (5,000), and `EXPIRED_REF_LIMIT` (256);
- `WS_PATH` (empty), `TOKEN` (empty), `TOKEN_PARAM` (`token`), and
  `TRANSPORT` (`unknown`).

All `*_MS` client/workload values are milliseconds. A zero heartbeat interval
disables client heartbeats; otherwise its timeout must be shorter than the
interval. `TARGET_URL` is required by the client, while `TARGET_URLS` may hold
comma-separated targets through `just load-run`. `WS_PATH`, when set, is
appended to each target URL. The client adds `vsn=2.0.0` and rejects another
`vsn`.

`TOPICS` is parsed and validated by the reusable client configuration, but the
eight current workloads do not read it. Use the profile-specific `TOPIC`,
`BROADCAST_TOPIC`, or `GUARDRAIL_TOPIC`; setting `TOPICS` alone does not change
their joins.

Client timeouts and session/delivery durations must be positive integers.
`OPERATION_INTERVAL_MS` and `BROADCAST_WARMUP_MS` may be zero.
`BROADCAST_GROUP_SIZE` must be at least 2; expected recipients must be at
least 1 and strictly less than the group size. `LOAD_GENERATOR_INDEX` is a
non-negative integer. Profile files accept only `constant-vus`,
`per-vu-iterations`, or `constant-arrival-rate`, require a non-empty `exec`
and threshold arrays, and require positive VUs or arrival-rate allocation.

The benchmark contract is explicit: `echo` returns the submitted marker;
`broadcast` and `broadcast_ack` fan out unchanged payloads;
`presence_track`/`presence_untrack` produce matching `presence_diff` entries;
and `guardrail:forbidden` rejects joins.

## Metrics

Every custom metric carries client tags including `transport`; scenario
clients also add `scenario_operation`. Error and presence metrics add bounded
operation-specific tags.

| Type | Metrics |
|---|---|
| Trend (milliseconds) | `phoenix_ws_establish_duration`, `phoenix_join_duration`, `phoenix_push_reply_duration`, `phoenix_leave_reply_duration`, `phoenix_heartbeat_reply_duration`, `phoenix_broadcast_delivery_duration`, `phoenix_presence_delivery_duration` |
| Counter | `phoenix_sessions_opened`, `phoenix_sessions_closed`, `phoenix_join_replies`, `phoenix_push_replies`, `phoenix_leave_replies`, `phoenix_heartbeat_replies`, `phoenix_late_replies`, `phoenix_client_errors`, `phoenix_protocol_errors`, `phoenix_decode_errors`, `phoenix_unmatched_replies`, `phoenix_join_timeouts`, `phoenix_push_timeouts`, `phoenix_leave_timeouts`, `phoenix_heartbeat_timeouts`, `phoenix_broadcast_deliveries`, `phoenix_presence_events`, `phoenix_unexpected_client_errors` |
| Rate | `phoenix_ws_failure_rate`, `phoenix_join_rejection_rate`, `phoenix_join_timeout_rate`, `phoenix_push_timeout_rate`, `phoenix_leave_timeout_rate`, `phoenix_heartbeat_timeout_rate`, `phoenix_broadcast_delivery_rate`, `phoenix_presence_delivery_rate`, `phoenix_scenario_operation_rate` |

The mixed profile uses k6's built-in `http_req_duration` and
`http_req_failed`; there is no separate custom HTTP metric. k6's built-in
`checks` metric covers the terminal workload assertions. Trends are declared
as time values, so k6 reports their usual time statistics and percentiles.

Client results show symptoms, not necessarily server saturation. Correlate
them with the benchmark server's `/stats`, Beryl telemetry, host CPU/network
data, file descriptors, ports, proxy/NAT utilization, and generator health.

Interpret the summary in this order:

1. `checks` and `phoenix_scenario_operation_rate` answer whether complete
   workload operations succeeded. Protocol, decode, unmatched-reply, and
   unexpected-client errors identify client/protocol correctness failures.
2. Join rejection rates separate explicit server policy from timeouts.
   Timeout rates mean no qualifying reply arrived before the client deadline;
   broadcast/presence delivery rates mean the expected fan-out or diff was
   observed before its delivery deadline.
3. Compare latency trends across equivalent repeated runs, especially their
   tails; do not treat a percentile from one short run as a capacity result.
4. For arrival-rate runs, `dropped_iterations` or rising active/max VUs means
   the generator could not schedule the requested rate. Generator CPU, event
   loop pressure, FDs, and ephemeral ports can produce client failures while
   `/stats` remains healthy.
5. Rising socket-runtime mailbox/run queue, target resource saturation, or
   telemetry latency concurrent with client degradation points toward the
   target. Healthy target signals with saturated generators, NAT, or proxies
   point elsewhere. Telemetry handlers themselves can become the bottleneck.

## Remote, clustered, and distributed execution

Keep target and generators on time-synchronized hosts. Record hardware and
topology rather than provider marketing names. Comma-separated target URLs
distribute VUs round-robin:

```sh
GIT_SHA="$(git rev-parse HEAD)" \
RUNTIME="OTP 28; Gleam 1.16.0" \
HARDWARE="8 vCPU, 16 GiB, Linux kernel x.y" \
SOURCE_IP="198.51.100.10" \
CLUSTER="2 nodes, round-robin load balancer" \
TARGET_LABEL="staging-a" RUN_ID="mist-001" \
just load-run push-round-trip \
  wss://node-a.example/socket,wss://node-b.example/socket mist
```

For multiple generators, use disjoint k6 execution segments. Every host must
use the same sequence, profile, target list, and effective settings:

```sh
# Generator 0
EXECUTION_SEGMENT="0:1/2" EXECUTION_SEGMENT_SEQUENCE="0,1/2,1" \
LOAD_GENERATOR="load-a" LOAD_GENERATOR_INDEX=0 LOAD_GENERATOR_COUNT=2 \
SOURCE_IP="198.51.100.10" RUN_ID="mist-002" \
just load-run idle-connections wss://target.example/socket mist

# Generator 1
EXECUTION_SEGMENT="1/2:1" EXECUTION_SEGMENT_SEQUENCE="0,1/2,1" \
LOAD_GENERATOR="load-b" LOAD_GENERATOR_INDEX=1 LOAD_GENERATOR_COUNT=2 \
SOURCE_IP="198.51.100.11" RUN_ID="mist-002" \
just load-run idle-connections wss://target.example/socket mist
```

`EXECUTION_SEGMENT` partitions work. `LOAD_GENERATOR_INDEX` only namespaces
deterministic participant and broadcast-group IDs and participates in target
selection; it does not partition execution. `LOAD_GENERATOR_COUNT` is metadata.
For broadcast runs, each generator's effective VUs should be divisible by
`BROADCAST_GROUP_SIZE`, or `BROADCAST_EXPECTED_RECIPIENTS` must fit the
smallest complete group. Groups are generator-local, so separate generators
do not acknowledge one another's broadcasts.

## Capacity prerequisites

Defaults differ by OS, container runtime, listener, OTP release, and workload.
Treat these as checks, not universal tuning values:

- Raise the target and generator process/service file-descriptor limits above
  expected sockets plus files, pipes, listeners, and monitoring overhead.
  Verify the effective limit inside containers.
- Inspect Linux `net.ipv4.ip_local_port_range`. One source-IP/destination tuple
  has finite ephemeral ports; add source IPs or target addresses instead of
  hiding exhaustion with unsafe TCP reuse settings.
- Inspect `net.core.somaxconn` and `net.ipv4.tcp_max_syn_backlog` for
  connection-rate tests. Kernel ceilings help only when listeners and proxies
  request compatible backlogs.
- Monitor FDs, ports, `TIME_WAIT`, accept errors, retransmits, packet loss, and
  generator dropped iterations. Change one setting at a time.
- Record effective BEAM flags and high-water marks. `+P` caps processes, `+Q`
  caps ports, and `+K true` requests kernel polling. Do not size them from
  connection count alone or assume kernel polling helps every platform.
- Monitor NAT/proxy connection tables. `SOURCE_IP` is metadata; it does not
  change network identity. Beryl's per-IP limit sees the TCP peer, so all
  clients behind one proxy share a bucket.
- Set an edge WebSocket frame/message limit at or below
  `BERYL_MAX_INBOUND_FRAME_BYTES`, plus a matching upgrade/body limit. Beryl
  measures after frame assembly and does not bound transport/proxy buffering.

Do not copy `sysctl`, `+P`, or `+Q` values blindly. Increase a limit only after
a controlled run approaches it, then repeat the baseline. See the
[production hardening guide](https://beryl.tylerbutler.com/guides/production-hardening/).

## Results and metadata

`handleSummary` writes a JSON object with `metadata` and the complete k6
`result`. The default path is
`load/results/<profile>-summary.json`; set a unique `SUMMARY_PATH` for every
measured run. `load/results` is generated/ignored except for `.gitkeep`.

Metadata schema version 1 contains:

- `profile`, `git`, `transport`, `runtime`, `hardware`, `source_ip`, `cluster`,
  `load_generator`, `load_generator_index`, `target_label`, and `run_id`;
- `segmentation.execution_segment`, `execution_segment_sequence`,
  `load_generator_index`, and `load_generator_count`;
- `target_count`;
- the full effective k6 `executor`, including `exec`;
- `workload`: `exec`, all effective topic/event names, broadcast group size,
  expected recipients, and warmup;
- `session`: effective session, operation, delivery, connect, reply, leave,
  heartbeat interval, and heartbeat timeout values.

Unset descriptive values become `unknown`; cluster defaults to `single-node`,
generator to `local`, segment to `0:1` with sequence `0,1`, generator indexes
to `0`, count to `1`, and run ID to `unassigned`. Target URLs, `TOKEN`, and
`TOKEN_PARAM` are deliberately omitted. Do not put credentials into labels or
free-form metadata. [`baseline-metadata.json`](k6/baseline-metadata.json) is a
complete non-secret example for the checked-in `protocol-smoke` profile.

Copy each generator's summary and server log to durable storage before
destroying hosts or containers. Retain the raw per-generator summaries,
effective environment, image/commit identifiers, and time-aligned server and
host telemetry under the same run ID. Never average p95/p99 values from
separate summaries: percentiles are not composable. Preserve each summary for
side-by-side comparison, or send raw/time-series samples to a backend that can
calculate an aggregate distribution. Use unique paths such as
`load/results/<run-id>-<generator>-summary.json` to prevent generators or
repeats from overwriting one another.

## Controlled baselines

1. Pin the commit, k6 image digest, target image digest, OS and OTP settings,
   topology, profile, and effective environment.
2. Pass `protocol-smoke`, then run an unrecorded whole-system warmup long
   enough for code loading, pools, and caches. `BROADCAST_WARMUP_MS` only
   coordinates group membership.
3. Reset the same initial state and run a predeclared number of measured
   repeats (at least three is a useful minimum), each with unique `RUN_ID` and
   `SUMMARY_PATH`.
4. Compare medians and spread, not the best run. Reject runs with generator,
   NAT, proxy, packet-loss, monitoring, or target saturation unrelated to the
   independent variable.
5. Change one variable—transport, VUs/rate, node count, or one tuning
   setting—and repeat the sequence.

Promote a metric into a performance threshold only after its definition and
percentile fit the operational objective, warmup is excluded, repeated runs
have acceptable variance, generator headroom is proven, and the failure budget
has an explicit rationale. Never derive a gate from one favorable run.

## Troubleshooting

| Symptom | Check |
|---|---|
| Port 8000 is occupied or the health check reaches another service | Choose another `PORT` for the server and update WebSocket and HTTP URLs; stop the conflicting listener only if you own it |
| `TARGET_URL is required` or URL/version errors | Supply an absolute `ws://`/`wss://` URL without fragments. The client adds missing `vsn=2.0.0` and rejects any other value or invalid query encoding |
| WebSocket upgrade returns 404 | Use `/socket` exactly once: put it in the target URL or in `WS_PATH`, not both |
| Mixed profile refuses to start | Set an absolute `HTTP_TARGET_URL`, normally `/health` |
| Heartbeats time out or configuration is rejected | Use zero interval only to disable client heartbeats; otherwise set a positive timeout strictly below the interval and align the client cadence with the server's heartbeat eviction window |
| Idle profile refuses to start | Session duration must cover the profile duration, use a non-zero heartbeat interval, and make the session longer than that interval |
| Broadcast delivery failures | Use a group size of at least 2, keep expected recipients between 1 and group size minus 1, ensure complete generator-local groups/divisible VUs, and allow enough warmup and delivery time |
| Join rejection in normal profiles | Confirm the topic, target `BERYL_*` guardrails, proxy peer-IP behavior, and server logs |
| Server exits or never becomes healthy | Inspect startup logs for bind/port conflicts, invalid heartbeat configuration, missing dependencies, or the wrong transport entry point; `/health` proves only that HTTP can answer |
| WebSocket failures or dropped iterations at high rate | Check generator VUs/CPU, ephemeral ports, FDs, NAT/proxy tables, listener backlogs, and target `/stats` before attributing failure to Beryl |
| `/stats` returns `503` or `504` | Preserve it as unavailable/overloaded telemetry; do not convert it to zeros |
| Summary file missing or owned unexpectedly | `load-run` mounts the repository and runs k6 as the current UID/GID; ensure the parent of `SUMMARY_PATH` exists and is writable, use a path under the mounted repository, and give every host/run a unique path |

## CI smoke and artifacts

The `load-smoke` GitHub Actions job runs a matrix of Erlang 27/28 and Mist/Ewe
on port 8000. It installs Gleam 1.16.0, validates `protocol-smoke`, builds the
fixture, waits up to 30 one-second health attempts, and runs the pinned k6
container. It enforces protocol/error thresholds only.

Every matrix leg uploads, even on failure:

- `load/results/server-<erlang>-<transport>.log`;
- `load/results/protocol-smoke-<erlang>-<transport>.json`.

The artifact is named
`protocol-smoke-erlang-<erlang>-<transport>`, warns rather than fails if files
are missing, and is retained for 7 days.

For same-repository pull requests, a final report job downloads the four
artifacts and creates or updates one marker-based PR comment. The comment
shows each runtime/transport result, diagnostic lifecycle timings, the combined
client/protocol error count, the smoke test's correctness scope, and concise
instructions for running repeatable throughput and latency tests. Fork pull
requests do not receive the comment because their `GITHUB_TOKEN` is read-only.
