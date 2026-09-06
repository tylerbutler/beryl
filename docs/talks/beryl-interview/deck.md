---
marp: true
theme: beryl
paginate: true
title: "beryl — type-safe real-time channels for Gleam on the BEAM"
---

<!-- _class: lead -->
<!-- _paginate: false -->

![w:130](../../../website/src/assets/beryl.webp)

# beryl

Type-safe real-time channels and presence
for **Gleam** on the **BEAM**

[beryl.tylerbutler.com](https://beryl.tylerbutler.com)

<!--
Start with a brief introduction and this summary:
"beryl is a library for building real-time features such as chat, live
cursors, and presence in Gleam, a typed language on the Erlang VM."

Set expectations up front:
- The API is stable. Version 1.0 is imminent. Before the talk, check whether
  it has shipped and give the current status. The production record is still
  short, so ask for reports from real applications. State this limitation
  early.
- Two packages: `beryl` (the core) and `beryl_mist` (the WebSocket transport).
  Explain the package split on the architecture slide.

TRANSITION: "First, I will explain the problem because it explains each
design decision."
-->

---

## Real-time is a distributed-state problem

- Chat rooms · live cursors · presence dots · collaborative editing
- Thousands of connections that constantly join, leave, and **crash**
- Ephemeral shared state that has to stay consistent across all of them

<!--
KEY LINE: "Any language can send bytes over a WebSocket. Connection and state
management are the difficult parts."

Describe the bookkeeping:
- Track each connection and its rooms.
- Remove state and notify the room when a laptop closes during a message.
- Route a message from server A to a client on server B.

Emphasize connection churn. Connections often stop without a clean
disconnect. Mobile networks fail, tabs close, and Wi-Fi connections drop.
The system must treat disconnection as normal operation.

And the state is ephemeral but correctness still matters: a stale presence
list means ghost users; a missed broadcast means two people see different
documents. Ephemeral state still requires correct behavior.

TRANSITION: "Most systems use the following approach."
-->

---

## The usual answer: build a runtime yourself

- WebSocket server + Redis pub/sub + sticky sessions
- Custom heartbeats, reconnect logic, cleanup jobs
- The platform does not provide these functions, so you assemble them from parts

<!--
Explain each part and why it is present. Each part supplies a missing
runtime capability:
- Your app server holds sockets in memory. When you run a second instance,
  messages cannot reach clients on the other server. Add Redis
  pub/sub as an out-of-process message bus.
- One process holds the connection state. Add sticky sessions at
  the load balancer so the client returns to the same server.
- Nothing detects dead connections. Add heartbeats, timeouts, and
  periodic cleanup jobs to remove stale connection state.

KEY LINE: "None of these pieces is your product. You wanted a chat room;
you now operate a small distributed systems platform."

Also note the additional failure modes. A Redis outage stops real-time
traffic. Sticky sessions conflict with autoscaling. Cleanup jobs can race with
reconnects.

TRANSITION: "A runtime included these capabilities in 1986, although its
design did not target the web."
-->

---

<!-- _class: divider -->

# The BEAM for real-time systems

Erlang's virtual machine was built for telephone switches:
millions of concurrent conversations that must not drop.

<!--
Assume that the audience has no Erlang background.

The history in 60 seconds: Erlang was built at Ericsson in the late 80s
to run telephone switches. The requirements were strict: huge numbers of
simultaneous calls, hardware that fails, software that must be upgraded
without hanging up anyone's call, and no tolerance for one call crashing
another. Reports cite Ericsson's AXD301 switch at "nine nines" availability,
which is about 30 ms of downtime a year.

Use this comparison: "A chat room is a conference call. A presence list is a
dial tone. The web now has problems that Erlang was designed to solve."

Modern example: Before its acquisition, WhatsApp ran approximately 2 million
TCP connections on one BEAM node with a small engineering team.

Three ideas coming, one slide each: processes, supervision, distribution.

LIKELY QUESTION: "Why is Erlang not more common?" Answer that its unfamiliar
syntax and dynamic typing limited adoption. Elixir made the syntax more
familiar, and Gleam adds static typing.
-->

---

## Processes: concurrency at large scale

- Millions of tiny, isolated, share-nothing processes per node
- No shared memory or locks; processes only send messages
- beryl uses connection processes at the transport edge and one shared app runtime
- Per-socket models stay isolated by ID and callback failures are contained

<!--
Give these numbers:
- A BEAM process starts at a few KB (~2-3 KB including its heap). An OS
  thread reserves megabytes of stack. This is a difference of three orders of
  magnitude and makes actor-oriented transport, runtime, presence, and worker
  designs inexpensive.
- Each process has its OWN heap and its own garbage collector. No global
  GC pause: one process collecting never stalls the others. This is why
  BEAM latency stays flat under load.
- Scheduling is PREEMPTIVE: the VM runs one scheduler per core and forcibly
  swaps processes after a reduction budget. Contrast with async/await:
  cooperative scheduling means one missing `await` or busy loop starves
  the event loop. On the BEAM a busy process cannot starve its neighbors.

Isolation is the main point: share no state. The only way two
processes interact is by copying a message into the other's mailbox.
No shared memory means no locks or data races.

Be precise about beryl's topology: it does not spawn an application actor per
socket. Mist/Ewe own their normal WebSocket connection processes, while one
shared runtime actor stores every socket's typed model and topic membership.
The runtime handles app callback crashes and applies a scoped policy: reject a
crashing join, close a topic for a crashing message, and tear down only that
socket for a crashing `Info`. Other sockets and the runtime survive.

TRANSITION: "Isolation also changes the effect of a crash. Next, I will
explain Erlang supervision."
-->

---

## Supervision: crashing is a strategy

- Supervisors watch processes and restart them in a known-good state
- "Let it crash": avoid defensive try/catch chains; fail fast and restart clean
- `beryl.child_spec` contributes a small **one-for-one** subtree:

```
application supervisor
 └─ beryl subtree (Transient)
     ├─ runtime (significant Transient)
     └─ connection limiter (optional)

presence · groups     application-owned sibling actors
PubSub                Erlang pg lifecycle
```

<!--
"Let it crash" can sound unsafe. Explain its limits:
- Most defensive code handles errors that the process cannot
  recover from in-place (corrupt state, impossible input). Erlang's
  answer is to stop the process. A supervisor restarts it
  from a known-good initial state. You trade "unknown corrupt state"
  for "known clean state" in microseconds.
- This method does not ignore errors. The runtime logs crashes and limits
  restart rates. A repeated crash escalates through the supervision tree.
  The application still handles expected errors, such as bad user input and
  rejected joins, as values. Let-it-crash applies to unpredicted errors.

Explain the actual tree:
- `beryl.child_spec(config, init:, update:)` returns a stable `Sockets`
  handle plus the beryl subtree's child specification.
- The runtime is the significant transient child. A genuine runtime crash is
  restarted under the same registered name; the optional limiter is its
  sibling.
- Transports monitor the exact runtime pid. If it dies, existing WebSockets
  close instead of becoming zombies attached to a successor.
- `beryl.stop` drains only this subtree. Presence and groups are borrowed,
  application-owned actors, and PubSub is backed by `pg`; beryl does not stop
  any of them.

LIKELY QUESTION: "What happens to in-flight state after a restart?" Explain
that the runtime restarts with the app's `init`/`update` closures,
but connected-socket models and topic membership are gone. Monitored
transports close, clients reconnect and rejoin, and anything durable belongs
in your database. Real-time state is a cache of "now," not a ledger.
-->

---

## Distribution: clustering built into the runtime

- Nodes connect to each other; processes send messages across machines transparently
- `pg` process groups = distributed pub/sub, **in the standard library**
- No Redis. No message broker. No sidecar.

<!--
State the claim precisely: sending a message to a process on another machine
uses the same one-line operation as a local send. The VM
handles connections, serialization, and delivery. Erlang nodes form a
mesh when they know each other's names and share a secret cookie.

`pg` (process groups) is the primitive beryl builds on:
- A process joins a named group; anyone can ask for the group's members
  ACROSS THE WHOLE CLUSTER; membership updates propagate automatically,
  and dead processes are removed when they die (the runtime monitors them).
- This is pub/sub, the function that slide 3 used Redis to provide. It is in
  Erlang's standard library and uses the same mechanism that WhatsApp scaled.

beryl's PubSub module is a thin, typed wrapper over pg, generic over its
payload type. Broadcasts carry native Gleam values across nodes without an
application encoding step; Erlang distribution serializes the terms. State the
architectural rule slowly: "PubSub is the ONLY cross-node
primitive in beryl. The app runtime, presence actors, groups, and rate
limiters are node-local. Scaling out means starting more nodes and letting
pg carry broadcasts and presence sync between them." A later slide contains
a diagram.

Mention a security constraint that the production slide will explain.
Distribution assumes that every node in the cluster is trusted. It is a
clustering protocol, not a security boundary.

TRANSITION: "The runtime supplies these capabilities, but Erlang does not
supply static types. Gleam closes that gap."
-->

---

## Gleam: types on the BEAM

- Small, friendly, **statically typed** language compiling to Erlang
- Full OTP interoperability; actors, supervisors, and `pg` are available
- BEAM capabilities with compiler checks

<!--
Describe Gleam for people who have not used it:
- Gleam reached 1.0 in 2024. It is young but stable, has a welcoming
  community, and provides clear compiler error messages.
- SOUND static types: no `any` escape hatch, no nil, and errors are
  values (`Result(ok, err)`) rather than exceptions. The compiler rejects
  many type-related errors before the program runs.
- Deliberately SMALL language: no macros, no inheritance, no operator
  overloading. You can learn most of it in a weekend. Its small size is a
  design feature.
- Compiles to Erlang source, so OTP interop is first-class: actors,
  supervisors, and pg from the last three slides are available with types.
  Gleam also has a JavaScript target, but beryl supports only the BEAM because
  it depends on the Erlang runtime.

Explain why this matters. Dynamic typing was a common historical
objection to Erlang and Elixir. Real-time systems are long-running,
message-driven, and changed often. In these systems, you need a
compiler tracking every message shape and state type.

KEY LINE: "Gleam is the answer to 'I want the BEAM but I also want the
compiler to catch my mistakes.' beryl applies that type system to channels."
-->

---

## Phoenix Channels semantics, with a compiler

- **Sockets + topics**: one typed `init`/`update` pair routes every topic
- **Presence**: reports who is online; CRDT-backed and works across nodes
- **PubSub**: distributed broadcast over `pg`
- **Groups**: named topic collections for multi-topic fan-out
- **Transport**: Mist/Ewe WebSockets and an explicit pluggable codec

<!--
First, give the mental model for people who do not know Phoenix.
Clients open one WebSocket and then join any number of topics over it:
"room:lobby", "room:42". In beryl, the app's one `update` function receives
`Join`, `Message`, `Closed`, raw `Binary`, and typed `Info` events and routes
them by matching topic strings or `beryl/topic` patterns. It returns ordered
effects to accept/reject, reply, push, broadcast, or kick a topic. There is no
channel registry or per-topic callback module.

For people who know Phoenix, explain that beryl uses the same model and wire
format:
literally the same JSON array framing, `[join_ref, ref, topic, event,
payload]`. The Phoenix JavaScript client connects to beryl UNCHANGED.
This compatibility gives beryl access to established client libraries,
reconnect logic, and documentation.

The differentiator is in the title: each socket's app model and server-side
message type are compiler-checked end to end. Phoenix stores connection state
in a dynamic map; beryl threads the app's concrete `model` through `Next` and
delivers typed server messages as `Info(msg)` (next two slides show it).

LIKELY QUESTION: "Why not use Phoenix?" Give this answer:
1. If you are building in Gleam, staying in one typed language across
   the whole stack beats bridging into Elixir.
2. Typed per-socket models, server messages, and effect results catch at
   compile time what Phoenix often represents dynamically.
3. beryl is smaller and unbundled: codec and transport are both
   swappable interfaces, not framework internals.
State the other tradeoff. Phoenix is mature and extensive.
beryl's API is stable, but its production use is limited. If you are
on Elixir, use Phoenix.
-->

---

## A real-time server, whole

```gleam
pub fn main() {
  let assert Ok(#(sockets, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: init,
      update: update,
    )

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  let assert Ok(_) =
    mist_transport.handler(
      sockets,
      server.default_config("/socket/websocket"),
      http_fallback,
    )
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
```

<!--
Explain each line. This code is the complete server, not an excerpt:

1. `beryl.child_spec(config, init:, update:)` validates config and returns
   the stable `Sockets` handle plus a child spec for YOUR supervision tree.
   The codec argument is required: `wire.phoenix_codec()` opts into Phoenix
   JSON and V2 binary framing; a custom codec is a config change, not a fork.
2. The app supplies one `init` and one `update`. `update` routes `room:*`,
   `document:*:*`, or any other namespace itself by pattern matching; there
   is no registration step to replay after a runtime restart.
3. `mist_transport.handler(...)` combines
   the WebSocket upgrade AND your regular HTTP handler into one Mist
   handler. Upgrades on `/socket/websocket` go to beryl; every other
   request falls through to `http_fallback`. One server, one port,
   both jobs.
4. `process.sleep_forever()` keeps this standalone demo alive. In a larger
   application, the root supervisor or host server already owns process
   lifetime.

State this limit so people do not copy the pattern into request code:
`let assert Ok(..)` makes the demo stop if startup fails. This behavior is
reasonable during startup. In request paths, pattern-match the `Result`.
-->

---

## Typed models: the compiler checks every update

```gleam
pub type Model {
  Model(username: Option(String))
}

pub type Msg {
  UserLoaded(String)
}

fn update(model: Model, ev: socket.Input(Msg)) {
  case ev {
    socket.Join("room:" <> _, payload, ref) -> {
      let username = decode_username(payload)
      socket.Next(Model(username: Some(username)), [
        socket.AcceptJoin(ref, None),
      ])
    }
    socket.Message(topic, "typing", _payload, _ref) ->
      socket.Next(model, [socket.BroadcastFrom(topic, "typing", json.null())])
    socket.Info(UserLoaded(username)) ->
      socket.Next(Model(..model, username: Some(username)), [])
    _ -> socket.Next(model, [])
  }
}
```

<!--
This snippet shows the main type-safety benefit. Spend time on it.

Phoenix assigns are a dynamic map. In beryl, YOU define the per-socket
`Model`, and the runtime threads exactly that type through every `update`.
Rename `username` and every use fails to compile.

Explain the flow:
- Wire payloads are still untrusted `Dynamic`, so the join branch must decode
  them. That is the validation boundary.
- Once decoded, app state is an ordinary typed model. Returning
  `Next(new_model, effects)` determines exactly what the next event sees.
- Effects are plain exhaustive data: accept/reject, reply, push, broadcast,
  kick. Their list order is wire order.
- `Msg` is also the app's type. Other actors send through the socket's
  `Sender(Msg)` and `update` receives `Info(UserLoaded(...))` with no
  callback-level erasure.
- Cleanup is an `socket.Closed(topic, reason)` branch. Returning
  `socket.Stop(reason)` tears down the whole socket.

Socket-level `on_connect` remains the Phoenix `UserSocket.connect` analogue:
it can reject the upgrade and attach validated metadata to `ConnectSeed`
before `init` runs.

TRANSITION: "Next, I will run the application."
-->

---

<!-- _class: divider -->

# Demo: live cursors

`examples/cursors`: wildcards · presence · `broadcast_from` · rate limiting

<!--
Before the interview:
- Rehearse the demo: `cd examples/cursors`, check the README run
  command, warm the build.
- ⚠ On this machine, the paperless-ngx container often uses port 8000.
  Stop it or run the example on another port before going
  live. Check with: lsof -i :8000
- Have a fallback: a 20-second screen recording or GIF ready in case
  live networking fails. Do not debug on stage.

Demo script, about two minutes:
1. Open two browser windows side by side, join the same room. Move the
   mouse. The cursor appears in the other window. Pause before you explain it.
2. "Each tab is one WebSocket whose connection process handles edge work,
   while beryl's shared runtime holds a separate typed model for each socket."
   (Refer to the processes slide without claiming an app actor for each socket.)
3. Point at the code. `broadcast_from` sends to everyone except the sender,
   so the sender does not receive its own cursor event.
4. Open a third tab. The presence list grows. Close it without a clean
   disconnect. The presence list shrinks. "The transport reported the disconnect, the runtime
   delivered `Closed`, and the app-owned presence worker untracked the
   session. Cleanup follows the current app-dispatch lifecycle."
5. Mention the rate limiter: mousemove fires hundreds of events/sec.
   A token-bucket limiter controls this event rate for each socket.

Mention two other examples: `chatrooms` (auth via on_connect,
join rejection, groups, typing indicators) and `collab_docs`
(client-side CRDT document editing).

TRANSITION: "The presence list contains the most difficult problem
in the library. Next, I will explain it."
-->

---

## Online presence is harder than it sounds

- The same user joins on node A and leaves on node B **concurrently**
- Timestamps fail · locks do not scale · last-write-wins drops users
- Common direct approaches can ghost users or show phantoms

<!--
Give a concrete failure example:

Scenario: Alice has the app open on her phone and laptop, hitting two
different nodes. She closes the laptop at the same moment her phone
reconnects. Node A processes a LEAVE while node B processes a JOIN
concurrently, with replication delay between them.

Explain why the direct solutions fail:
- Shared set in a database: every join/leave is now a write to a
  central store. This adds latency, contention, and a single point of failure
  for something that changes hundreds of times a second.
- Timestamps + last-write-wins: clocks skew across nodes. The leave
  can carry a LATER timestamp than a join that occurred after the leave.
  Alice is online but shows offline (ghosted), or the
  reverse (a phantom). Wall clocks do not define causal order.
- Locks/consensus per update: correct but too slow for presence
  churn. This approach would use consensus for each status update.

KEY LINE: "The set of online users has no single authoritative event order.
We need a data structure that does not require one."

LIVE AID: Open `presence-demo.html` from this directory in a browser
before the talk. It is one file and does not require a server.
Arrow keys change steps, and 1/2/3 select scenarios. Scenario 1 shows the
Alice story above with the naive set. Step through it while talking.
Scenario 2 shows phantom users after a node crash. Stop before scenario 3
because the next slide explains it.
-->

---

## Presence is a CRDT

- Add-wins observed-remove set with causal context
- Nodes that have seen the same events **agree in any order**
- Conflict resolution without coordination, locks, or a database
- Phoenix-compatible `joins` / `leaves` diffs on the wire

<!--
Define a CRDT in plain language: a data structure whose MERGE
operation is commutative, associative, and idempotent. Therefore,
replicas can apply updates in any order, including duplicate or delayed
updates, and
they still converge to the same value. No central lock and no
"who wins" tiebreak at runtime. The convergence is a property of the
data structure, not of reliable network order.

Decode the name on the slide, one term at a time:
- OBSERVED-REMOVE: you can remove only entries that you have seen.
  A leave cannot cancel a join that it did not know about. This rule
  prevents the ghost-user bug from the last slide.
- ADD-WINS: when a join and leave are concurrent and neither operation knew
  about the other, the tie breaks toward PRESENT. This bias fits
  presence: a user flickering online for an extra second is cosmetic;
  showing a connected user as offline is a bug.
- CAUSAL CONTEXT: vector-clock-style metadata tells the structure
  whether two events were concurrent or ordered. This is the
  bookkeeping that replaces timestamps.

Use this summary: "Any two nodes that
have seen the same events agree on who is present, regardless of the
order they saw them in."

LIVE AID: Switch `presence-demo.html` to scenario 3 by pressing 3. It
replays the same Wi-Fi failure with tagged joins. The stale leave
arrives late and removes ONLY the tag it observed, and both nodes
converge with Alice online. The final step covers the crash case too
(origin-tagged entries dropped when the runtime reports a node down).
The animation shows that the same incorrect message order produces the correct
result.

Implementation notes (brief): the CRDT comes from the `lattice_presence`
package. beryl wraps it in an OTP actor on each node. When local state is dirty,
periodic ticks publish the versioned **full CRDT state** over PubSub. Peers
merge it and surface non-empty local/merge diffs through `with_on_diff`.
Those replication payloads are not the client wire format. The app separately
emits Phoenix-compatible `presence_state` / `presence_diff` joins/leaves maps,
so the Phoenix JS Presence class renders beryl presence without modification.

LIKELY QUESTION: "Why not track it in Postgres or Redis?" Explain that
presence is high-churn ephemeral state; a DB adds a round-trip and a
single point of failure to every mouse-in or mouse-out event. It also retains
the concurrent-update problem because the conflict moves to the database.
-->

---

## Architecture: one slide

```
WebSocket transport     beryl_mist / beryl_ewe  (public transport SPI)
        │
Configured codec        beryl/wire  (required; Phoenix is one option)
        │
Shared runtime          per-socket models · topics · heartbeat · effects
        │
App update              Join · Message · Binary · Closed · typed Info
        │
PubSub                  Erlang pg — the ONLY cross-node layer

Presence · Groups       independent, application-owned actors
```

<!--
Describe the life of one message from top to bottom:
1. A WebSocket frame arrives at the TRANSPORT (beryl_mist). The
   transport owns the connection, edge limiter, and raw bytes. It does not
   know the app model.
2. The explicitly configured CODEC decodes text and, when available, binary
   frames into topic/event/payload/ref values. Decoded binary keeps binary
   telemetry classification; without a binary decoder it becomes a raw
   `Binary` event.
3. The RUNTIME, one shared OTP actor for each app, tracks socket models, joined
   topics, heartbeat state, and outstanding refs. There is no registry.
4. Your app's one `update` function runs and returns an ordered effect list.
5. If an effect broadcasts, PUBSUB sends it over pg, including
   to subscribers on other nodes. Each node's transports push to
   their local sockets.

State these two design rules slowly:
- "Everything above the bottom line is NODE-LOCAL. pg PubSub is the
  only thing that crosses machines. To scale out, start more nodes and
  cluster them. There is no shared state to migrate."
- "The transport talks to beryl only through the public
  `beryl/transport` SPI. beryl_mist is a plug-in. A
  different HTTP server, or a non-WebSocket transport, implements the
  same contract." This design explains the two-package repository structure.

LIKELY QUESTION: "Is the shared runtime actor a bottleneck?" Explain that app
dispatch and local fan-out are serialized there. Frame
size checks, message-rate shedding, and decoding happen in transport
connection processes before enqueueing. The actor is per app/node, not
per cluster; published capacity benchmarks remain important post-1.0 work.
-->

---

## Production status

**Built in:** per-IP connection caps · node-wide connection ceiling
token-bucket rate limits · same-origin WebSocket policy by default

**Deployment requirements:** edge proxy with a frame-size limit
Erlang distribution trusts every cluster node; keep the cluster closed

> The API is stable. Production use is still limited.

<!--
Introduce the slide with this security boundary: "Each real-time endpoint is
an open TCP connection. beryl supplies abuse controls and documents their
limits."

BUILT IN (caps and rate limits are on `beryl.Config`; the origin policy
is on the transport config):
- `with_max_connections_per_ip`: per-IP connection caps, plus
  `with_max_connections`, a
  node-wide total connection ceiling so one node
  cannot be socket-flooded past its capacity.
- `with_message_rate`: token-bucket rate limiting per socket. This is
  what tamed the cursor firehose in the demo.
- Origin checking on the transport defaults to SAME-ORIGIN. Browsers can open
  cross-site WebSockets, so this closes cross-site hijacking by
  default rather than by remembering to configure it.

STILL ON YOU. State two boundaries:
1. Frame-size limits are enforced POST-ASSEMBLY: the transport buffers
   a complete frame before beryl measures it. A hostile client can
   declare a huge frame, or stream endless fragments, and increase the
   buffer BEFORE the check runs. In production, you MUST cap frame
   size at an edge proxy (nginx/HAProxy/Envoy). beryl's limit is
   defense-in-depth for processing cost, not a memory bound. The
   upstream fix (cap-before-buffer in mist/gramps) is tracked publicly.
2. Erlang distribution, which provides the clustering from the pg slide,
   TRUSTS every peer completely. It is a clustering protocol, not a security
   boundary. A hostile node can inject any internal traffic. Closed
   cluster, strong cookie, TLS distribution. `SECURITY.md` describes these
   requirements.

Explain why these limits matter. Users can defend a boundary only when the
documentation identifies it. Repeat that the API is stable but production use
is still limited. The documents state these boundaries to help users deploy
the library safely.
-->

---

## Earde

### Earde is the community network for open source communities.

It lets maintainers connect a project through GitHub and give it a verified community home, or connect it to a broader existing community or ecosystem. Each community combines Discord-like live interaction with the structure, searchability, and long-term memory of traditional forums.

https://earde.com/

> Earde uses beryl!

---


## The ecosystem around it

```
phoenix_channel_fixtures ──── shared wire-format test data
        │                            │
      beryl (server) ◄── Phoenix wire ──► aquamarine (Gleam client)
        │                            │
   beryl_mist (WS)                roost · gluegun
```

Use aquamarine for a BEAM client. Use the official PhoenixJS client for JavaScript.

<!--
beryl is the server half of a matched pair. Explain each box:
- `aquamarine`: the Gleam client runtime. It can join topics, receive
  broadcasts, and synchronize presence from Gleam code. The server and client
  use one typed language.
- `roost`: a pure Phoenix wire-protocol library with frame constants,
  encode/decode, and reply helpers. It has no IO or runtime. aquamarine builds
  on it.
- `gluegun`: the client-side WebSocket transport (aquamarine's
  counterpart to beryl_mist).
- `phoenix_channel_fixtures`: a shared package of CANONICAL wire-format test
  data. beryl, aquamarine, and
  roost all run their codecs against the SAME fixtures in CI.

KEY LINE: "Wire protocols drift when each side tests against its own
assumptions. Shared conformance fixtures verify that the server and client
dialects are the same. If one changes incorrectly, the build fails."

Repeat that the client-side Gleam stack is optional. The standard Phoenix
JavaScript client works with beryl, including presence. A user can run Gleam
on the server and phoenix.js in the browser from the first day.
-->

---

<!-- _class: lead -->

## Try it and challenge the design

**Docs**: [beryl.tylerbutler.com](https://beryl.tylerbutler.com)
**Discuss**: [earde.com/c/beryl/s/general](https://earde.com/c/beryl/s/general)
**Chat**: the Gleam Discord
**Source**: [github.com/tylerbutler/beryl](https://github.com/tylerbutler/beryl)

<!--
CLOSE with three points:
1. Summarize: "The BEAM supplies inexpensive processes, supervision, and
   clustering. Gleam adds the type system. beryl applies both to real-time
   sockets."
2. Ask for feedback. The API is stable, and version 1.0 is available or near.
   Reports from real applications now guide the roadmap. Ask the audience to
   build a small application and report problems.
   Give a concrete start: clone the repo, run `examples/cursors`, and read the
   Quick Start.
3. Give contact options. Use the Earde space on screen for design questions,
   proposals, and project examples. Use the Gleam Discord for short questions.
   Use GitHub for issues and pull requests.

Leave this slide visible during questions because it contains all links.

LIKELY QUESTIONS NOT COVERED BY EARLIER NOTES:
- "Production users?" State that the library is young and early
  adopters are the audience right now; the examples and conformance
  suites are the current proof of behavior.
- "What comes after 1.0?" Capacity benchmarks, upstream transport-memory
  limits before buffering, and changes based on early production feedback.
- "Does it work with Elixir/Phoenix apps?" beryl uses the same wire protocol,
  so Phoenix clients work with beryl servers. It is a Gleam server library,
  not a Phoenix replacement inside an Elixir app.
-->
