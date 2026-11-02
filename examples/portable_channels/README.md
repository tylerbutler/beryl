# Portable channels

## Overview

A Cloudflare Durable Object hosts one match. Each WebSocket uses
`beryl_protocol` for channel lifecycle decisions and Roost for Phoenix text
and binary framing. The official Phoenix JavaScript client handles client
references, joins, and reconnects.

The example has a counter, an authoritative snapshot, and a persistent roster.
It does not include Monk or deploy either application.

## Run locally

From the repository root:

```sh
just deps
cp examples/portable_channels/.dev.vars.example examples/portable_channels/.dev.vars
```

Set `JOIN_TOKEN` in `.dev.vars` to a local test value, then run:

```sh
pnpm -C examples/portable_channels dev
```

Connect with the official client:

```js
import { Socket } from "phoenix";

const socket = new Socket("ws://localhost:8787/matches/demo/socket");
const channel = socket.channel("match:demo", { token: "<your local JOIN_TOKEN>" });
channel.on("snapshot", (snapshot) => console.log(snapshot));
socket.connect();
channel.join().receive("ok", ({ snapshot }) => console.log(snapshot));
channel.push("increment", { command_id: crypto.randomUUID() });
```

Put credentials in the join payload. The worker permits only Phoenix's `vsn`
query parameter. This example's token represents the fixed principal `demo`;
a production host must validate a user credential and derive its principal
from that credential.

## Persistence and recovery

The host checkpoints protocol state in each WebSocket attachment before it
executes actions. Attachments include a format version, match code, principal,
and wall-clock save time. They exclude credentials and callbacks. The host
limits attachments to 16,000 UTF-8 bytes, below Cloudflare's 16,384-byte limit.

On wake-up, the host restores membership, generations, and correlation state.
It accounts for elapsed time before processing new commands. It requires a
rejoin for unrecoverable application work and a reconnect for invalid
attachments or backward clock data. Each rejoin validates the credential and
returns a fresh authoritative snapshot.

The object uses one alarm for the earliest connection deadline. Heartbeats
refresh that connection's deadline; application messages do not. Channel
leave, disconnect, and heartbeat expiry do not remove a player from the roster.

The host commits a counter mutation and its stable command ID in one storage
transaction. Retrying the ID returns the recorded response, including after
a lost reply, reconnect, or hibernation. Phoenix references only correlate
protocol replies. They do not replace command IDs.

The example retains up to 256 command records per match. At capacity, it
rejects new mutations rather than discard deduplication records. A production
application must define its own retention and sequence-validation policy.
The host does not claim exactly-once delivery: a failure after committing a
command can lose its reply, and the client must retry the same command ID.

## Tests

```sh
just protocol-test
just portable-host-test
```

The pure suite runs on Erlang and JavaScript. The host suite uses Cloudflare's
local runtime, actual hibernatable WebSockets, and the official Phoenix
client. It forces Durable Object eviction to test restoration, lost work,
heartbeats, and command retries. Shared Phoenix fixtures check Roost framing.
No test needs a Cloudflare account.

## Subdirectories and boundaries

- [Protocol bridge](./src/README.md): bounded Gleam transitions, host actions,
  JSON FFI, and the Roost framing adapter.

## Interface

`worker.mjs:fetch` routes
`/matches/{code}/socket/websocket` to the `Match` Durable Object.
The Phoenix `Socket` constructor above takes `/matches/demo/socket` as its
base endpoint and appends `/websocket` before connecting. Direct WebSocket
clients must use the full suffixed path; `worker.mjs:matchCode` rejects the
unsuffixed path.
`wrangler.jsonc:durable_objects` binds `MATCHES` to that class and configures
its migration. The `gleam.toml` dependencies supply `beryl_protocol` and Roost;
the worker owns storage, authorization, and application commands.

## Invariants

- `worker.mjs:matchCode` allows 1–32 alphanumeric, underscore, or hyphen
  characters; the request handler rejects query keys other than `vsn`.
- `worker.mjs:authorize` requires the matching topic and `JOIN_TOKEN`,
  assigning the fixed demo principal.
- `worker.mjs:heartbeatTimeout`, `maximumFrameBytes`, and `maximumCommands`
  set limits of 60 seconds, 16,384 bytes, and 256 command records.
- `worker.mjs:checkpoint` bounds serialized attachments to 16,000 bytes;
  `increment` commits counter changes with command IDs in a transaction.

## Side effects

`worker.mjs:apply` checkpoints before executing protocol actions.
The worker sends/closes WebSockets, stores match/game/roster/command state,
and schedules alarms. The Gleam bridge emits actions rather than performing
host I/O.

## Verification

From the repository root: `pnpm -C examples/portable_channels build`.
`pnpm -C examples/portable_channels test` runs the strict JavaScript build,
JavaScript-target Gleam tests, and local Cloudflare Vitest integration tests.
No account or production deployment is needed for those local tests.
