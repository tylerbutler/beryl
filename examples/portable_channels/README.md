# Portable channels

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
