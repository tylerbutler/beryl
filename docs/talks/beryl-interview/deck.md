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
OPEN: Quick intro — who I am, what I work on. Then the one-liner:
"beryl is a library for building real-time features — chat, live cursors,
presence — in Gleam, a typed language on the Erlang VM."

Set expectations up front:
- The API is stable and locked — 1.0 is imminent (check whether it has
  shipped before the talk and say whichever is true). What's young is the
  production track record, and real-world reports are the thing I'm
  actively after. Saying this early buys credibility for what follows.
- Two packages: `beryl` (the core) and `beryl_mist` (the WebSocket transport).
  Don't explain why yet — that pays off on the architecture slide.

TRANSITION: "Before I talk about the library at all, I want to talk about
the problem, because the problem explains every design decision."
-->

---

## Real-time is a distributed-state problem

- Chat rooms · live cursors · presence dots · collaborative editing
- Thousands of connections — constantly joining, leaving, **crashing**
- Ephemeral shared state that has to stay consistent across all of them

<!--
KEY LINE: "The hard part was never sending bytes over a WebSocket —
any language can do that in an afternoon. The hard part is the bookkeeping."

Spell out the bookkeeping concretely:
- Who is connected right now? Which rooms is each connection in?
- When a laptop lid closes mid-message, who cleans up? Who tells the room?
- If you run two servers, how does a message on server A reach a
  client attached to server B?

Emphasize CHURN: connections don't politely disconnect — they vanish.
Mobile networks drop, tabs close, wifi blips. Failure is the steady state,
not the exception. Whatever you build has to treat disconnection as normal.

And the state is ephemeral but correctness still matters: a stale presence
list means ghost users; a missed broadcast means two people see different
documents. "Ephemeral" doesn't mean "allowed to be wrong."

TRANSITION: "So what does the industry usually do about this?"
-->

---

## The usual answer: build a runtime yourself

- WebSocket server + Redis pub/sub + sticky sessions
- Hand-rolled heartbeats, reconnect logic, cleanup jobs
- The platform doesn't help — so you assemble one from parts

<!--
Walk the pieces and WHY each one appears — each is a patch over a missing
runtime capability:
- Your app server holds sockets in memory → the moment you run a second
  instance, messages can't reach clients on the other box → add Redis
  pub/sub as an out-of-process message bus.
- Connection state is trapped inside one process → add sticky sessions at
  the load balancer so the client always lands on "its" server.
- Nothing notices dead connections → hand-roll heartbeats, timeouts, and
  periodic cleanup jobs to garbage-collect zombie state.

KEY LINE: "None of these pieces is your product. You wanted a chat room;
you're now operating a small distributed systems platform."

Also note the failure modes multiply: Redis down = all real-time down;
sticky sessions fight autoscaling; cleanup jobs race with reconnects.

TRANSITION: "Here's the thing — there's a runtime that shipped all of
this, as a built-in, in 1986. It just wasn't built for the web."
-->

---

<!-- _class: divider -->

# Why the BEAM?

Erlang's virtual machine — built for telephone switches:
millions of concurrent conversations that must not drop.

<!--
This is the 100-level section — assume ZERO Erlang background.

The history in 60 seconds: Erlang was built at Ericsson in the late 80s
to run telephone switches. The requirements were brutal: huge numbers of
simultaneous calls, hardware that fails, software that must be upgraded
without hanging up anyone's call, and no tolerance for one call crashing
another. Ericsson's AXD301 switch is famously cited at "nine nines"
availability — about 30ms of downtime a year.

The reframe that makes it land: "A chat room is a conference call.
A presence list is a dial tone. The web grew into Erlang's problem."

Modern proof point: WhatsApp famously ran ~2 million TCP connections on
a single BEAM node, with a tiny engineering team, before the acquisition.

Three ideas coming, one slide each: processes, supervision, distribution.

LIKELY QUESTION: "Why haven't I heard of it then?" — honest answer:
weird syntax and dynamic typing kept it niche; Elixir fixed the syntax
perception, Gleam fixes the typing. That's where this talk is going.
-->

---

## Processes: concurrency you don't ration

- Millions of tiny, isolated, share-nothing processes per node
- **One process per connection is the normal pattern**, not a hack
- No shared memory, no locks — processes only send messages
- A crash takes down one conversation, not the server

<!--
Numbers make this real:
- A BEAM process starts at a few KB (~2-3 KB including its heap). An OS
  thread reserves megabytes of stack. That's three orders of magnitude —
  it's why "a process per connection" is idiomatic here and absurd elsewhere.
- Each process has its OWN heap and its own garbage collector. No global
  GC pause: one process collecting never stalls the others. This is why
  BEAM latency stays flat under load.
- Scheduling is PREEMPTIVE: the VM runs one scheduler per core and forcibly
  swaps processes after a reduction budget. Contrast with async/await:
  cooperative scheduling means one forgotten `await` or hot loop starves
  the event loop. On the BEAM a busy process cannot starve its neighbors.

Isolation is the philosophical point: share NOTHING. The only way two
processes interact is by copying a message into the other's mailbox.
No shared memory means no locks, no data races, and — crucially —
no way for one connection's corrupted state to infect another's.

TRANSITION: "Isolation also changes what a crash means — which brings us
to the strangest and best idea in Erlang."
-->

---

## Supervision: crashing is a strategy

- Supervisors watch processes and restart them in a known-good state
- "Let it crash": no defensive try/catch webs — fail fast, restart clean
- beryl ships a **rest-for-one** tree:

```
supervisor
 ├─ coordinator      ← crash here restarts everything below
 ├─ presence
 └─ groups
```

<!--
"Let it crash" sounds reckless — unpack it carefully because someone
WILL push back:
- The insight: most defensive code handles errors you can't actually
  recover from in-place (corrupt state, impossible input). Erlang's
  answer: don't try. Let the process die, let a supervisor restart it
  from a known-good initial state. You trade "unknown corrupt state"
  for "known clean state" automatically, in microseconds.
- It is NOT "ignore errors": crashes are logged, restart rates are
  capped (a crash loop escalates up the tree), and EXPECTED errors —
  bad user input, rejected joins — are still handled as values.
  Let-it-crash is for the errors you didn't predict.

The diagram — explain rest-for-one concretely, top to bottom:
- Children start in order; each depends on the ones above it.
- If GROUPS crashes: only groups restarts. Presence and coordinator
  never notice.
- If the COORDINATOR crashes: presence and groups restart too, because
  their view of the world routed through it. Fresh, consistent state
  for all three — no half-alive system.

beryl embeds into YOUR app's supervision tree via `supervisor.start`, so
channels recover alongside the rest of your application — same
mechanism, one tree.

LIKELY QUESTION: "What about in-flight state when it restarts?" —
honest answer: node-local ephemeral state is rebuilt (clients rejoin,
presence re-tracks on reconnect); anything durable belongs in your
database anyway. Real-time state is a cache of "now," not a ledger.
-->

---

## Distribution: clustering built into the runtime

- Nodes connect to each other; processes message across machines transparently
- `pg` process groups = distributed pub/sub, **in the standard library**
- No Redis. No message broker. No sidecar.

<!--
The claim to make carefully: sending a message to a process on ANOTHER
MACHINE is the same one-line operation as sending it locally. The VM
handles connections, serialization, and delivery. Erlang nodes form a
mesh just by knowing each other's names and sharing a secret cookie.

`pg` (process groups) is the primitive beryl builds on:
- A process joins a named group; anyone can ask for the group's members
  ACROSS THE WHOLE CLUSTER; membership updates propagate automatically,
  and dead processes are removed when they die (the runtime monitors them).
- That is... pub/sub. The thing slide 3 deployed Redis for. It's in
  Erlang's standard library — it's the same machinery WhatsApp scaled on.

beryl's PubSub module is a thin, typed wrapper over pg — and here's the
architectural sentence to say slowly: "PubSub is the ONLY cross-node
primitive in beryl. Channels, presence actors, rate limiters — all
node-local. Scaling out means starting more nodes and letting pg carry
broadcasts between them." (This gets a diagram later.)

FORESHADOW (pays off on the production slide): distribution assumes
every node in the cluster is trusted — it's a clustering protocol, not
a security boundary. Hold that thought.

TRANSITION: "So the runtime is a gift. Historically it came with a tax:
no static types. That's the gap Gleam closes."
-->

---

## Gleam: types on the BEAM

- Small, friendly, **statically typed** language compiling to Erlang
- Full OTP interop — actors, supervisors, `pg` all available
- The BEAM's superpowers, with a compiler watching your back

<!--
Position Gleam for people who've never seen it:
- Reached 1.0 in 2024 — young but stable, with a notably welcoming
  community and some of the best compiler error messages anywhere.
- SOUND static types: no `any` escape hatch, no nil, and errors are
  values (`Result(ok, err)`) rather than exceptions. If it compiles,
  a whole class of runtime surprises is gone.
- Deliberately SMALL language: no macros, no inheritance, no operator
  overloading. You can learn essentially all of it in a weekend —
  that's a feature, not a limitation.
- Compiles to Erlang source, so OTP interop is first-class: actors,
  supervisors, pg — everything from the last three slides is available,
  typed. (There's a JavaScript target too, but beryl is BEAM-only —
  it exists precisely to use the runtime.)

WHY IT MATTERS FOR THIS TALK: dynamic typing was THE historical
objection to Erlang and Elixir. Real-time systems are long-running,
message-driven, and refactored constantly — exactly where you want a
compiler tracking every message shape and state type.

KEY LINE: "Gleam is the answer to 'I want the BEAM but I also want the
compiler to catch my mistakes.' beryl is what channels look like when
you take that seriously."
-->

---

## beryl ≈ Phoenix Channels, with a compiler

- **Channels** — topic handlers with wildcards: `room:*`, `document:*:*`
- **Presence** — who's online, CRDT-backed, works across nodes
- **PubSub** — distributed broadcast over `pg`
- **Groups** — named topic collections for multi-topic fan-out
- **Transport** — Mist WebSockets, Phoenix-compatible wire format

<!--
First give the MENTAL MODEL (for those who don't know Phoenix):
clients open ONE WebSocket, then join any number of TOPICS over it —
"room:lobby", "room:42". The server registers handlers against topic
PATTERNS: `room:*` matches any room; `document:*:*` matches segments,
so one handler serves every document channel. Messages on a topic go
to its handler; the handler can reply to the sender, push to that
client, or broadcast to everyone on the topic.

For those who DO know Phoenix: same model, same wire format —
literally the same JSON array framing, `[join_ref, ref, topic, event,
payload]`. The Phoenix JavaScript client connects to beryl UNCHANGED.
That's deliberate: a decade of client libraries, reconnect logic, and
docs come along for free.

The differentiator is in the title: every callback is TYPED. Phoenix
stores per-connection state in a dynamic map; beryl makes it a type
parameter the compiler tracks (next two slides show it).

INEVITABLE QUESTION — "Why not just use Phoenix?" Have this ready:
1. If you're building in Gleam, staying in one typed language across
   the whole stack beats bridging into Elixir.
2. Typed assigns and handler results catch at compile time what
   Phoenix catches in production.
3. beryl is smaller and unbundled: codec and transport are both
   swappable interfaces, not framework internals.
Concede the flip side honestly: Phoenix is battle-tested and huge;
beryl's API is stable but its production mileage is young. If you're
on Elixir, use Phoenix.
-->

---

## A real-time server, whole

```gleam
pub fn main() {
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let assert Ok(_) = beryl.register(channels, "room:*", new_channel())

  let assert Ok(_) =
    mist_transport.handler(
      channels,
      mist_transport.default_config("/socket/websocket"),
      http_fallback,
    )
    |> mist.new
    |> mist.port(8000)
    |> mist.start

  process.sleep_forever()
}
```

<!--
Walk it line by line — this is the whole server, not an excerpt:

1. `beryl.start(beryl.config(wire.phoenix_codec()))` — boots the channel
   runtime and returns a handle. The config takes a CODEC: Phoenix JSON
   framing ships in the box, but it's an interface — custom binary
   framing is a config change, not a fork.
2. `beryl.register(channels, "room:*", new_channel())` — binds a topic
   pattern to a channel definition. Call it as many times as you have
   channel types; patterns can be exact, prefix (`room:*`), or
   segment wildcards (`document:*:ops`).
3. `mist_transport.handler(...)` — the nice composition trick: it wraps
   the WebSocket upgrade AND your regular HTTP handler into one Mist
   handler. Upgrades on `/socket/websocket` go to beryl; every other
   request falls through to `http_fallback`. One server, one port,
   both jobs.
4. `process.sleep_forever()` — keeps main alive for a demo. In a real
   app you'd skip this and put beryl under your OTP supervision tree
   via `beryl/supervisor.start` — there's a supervision guide.

Caveat to say out loud so nobody copies it blindly: `let assert Ok(..)`
is demo-grade "crash if startup fails" — which, per the supervision
slide, is actually reasonable at boot. Inside request paths you'd
pattern-match the Result properly.
-->

---

## Typed assigns: the compiler checks your callbacks

```gleam
pub type RoomAssigns {
  RoomAssigns(username: String)
}

channel.new(fn(_topic, payload, socket) {
  let username = // ...decode from join payload
  channel.JoinOk(
    reply: None,
    socket: socket.set_assigns(socket, RoomAssigns(username:)),
  )
})
|> channel.with_handle_in(fn(event, payload, socket) {
  // socket is Socket(RoomAssigns) — guaranteed at compile time
  channel.NoReply(socket)
})
```

<!--
This is the core pitch in one snippet — spend time here.

"Assigns" = per-connection, per-topic state. In Phoenix it's a dynamic
map: `socket.assigns.username` might be a string, might be missing —
you find out at runtime. In beryl YOU define the type, and `Socket` is
parameterized by it: this channel's sockets are `Socket(RoomAssigns)`.

Walk the flow:
- `channel.new(join_fn)` — the join callback is the front door for a
  topic. It decodes the join payload with a proper decoder (untrusted
  input is `Dynamic` — the type system forces you to validate at the
  boundary, no silent coercion). It can REJECT the join, or accept and
  SEED the assigns. After this point, well-typed state is guaranteed.
- `with_handle_in` — handles client events. The socket parameter is
  `Socket(RoomAssigns)`; rename a field and every callback that touches
  it fails to compile. That's the whole pitch in one sentence.
- Return values are plain data, not macros: `NoReply(socket)`,
  `Reply(payload, socket)` to answer the sender, `Push(event, payload,
  socket)` to send something unrelated. The compiler makes you return
  exactly one of them — no forgotten replies.

Mention what's NOT on the slide (breadth without detail):
- `with_handle_info` — messages from the SERVER side (other processes,
  timers, domain actors), typed via a second type parameter.
- `with_terminate` — cleanup when the client leaves or vanishes.
- Socket-level `on_connect` hook — authentication ONCE per socket
  before any join; the Phoenix `UserSocket.connect` analogue. Reject
  there and no channel ever sees the connection.

TRANSITION: "Enough slides — let me show you the thing running."
-->

---

<!-- _class: divider -->

# Demo: live cursors

`examples/cursors` — wildcards · presence · `broadcast_from` · rate limiting

<!--
LOGISTICS (before the interview):
- Rehearse the demo cold: `cd examples/cursors`, check the README run
  command, warm the build.
- ⚠ On this machine port 8000 is often held by the paperless-ngx
  container — stop it or run the example on another port BEFORE going
  live. Check with: lsof -i :8000
- Have a fallback: a 20-second screen recording or GIF ready in case
  live networking misbehaves. Never debug on stage.

THE SCRIPT (~2 minutes):
1. Open two browser windows side by side, join the same room. Move the
   mouse — cursor appears live in the other window. Let it be visceral
   for a beat before explaining.
2. "Every one of these tabs is one BEAM process on the server — a few
   KB each. This pattern is why one node handles tens of thousands of
   these." (Callback to the processes slide.)
3. Point at the code: `broadcast_from` = everyone EXCEPT the sender —
   you don't need your own cursor echoed back.
4. Open a third tab → presence list grows. CLOSE it abruptly →
   presence shrinks. "Nobody sent a leave message. The process died,
   the runtime noticed, terminate ran, presence updated. That's
   supervision and monitoring doing the cleanup slide 3 hand-rolled."
5. Mention the rate limiter: mousemove fires hundreds of events/sec;
   a token-bucket limiter tames the firehose per socket.

Also in the repo, name-drop only: `chatrooms` (auth via on_connect,
join rejection, groups, typing indicators) and `collab_docs`
(client-side CRDT document editing — the fancy one).

TRANSITION: "The presence list I just showed hides the hardest problem
in the library. Let's look at it."
-->

---

## "Who's online?" is harder than it sounds

- Same user joins on node A and leaves on node B — **concurrently**
- Timestamps lie · locks don't scale · last-write-wins drops users
- Every naive approach ghosts someone or shows phantoms

<!--
Build the failure story concretely — this slide is pure problem setup:

Scenario: Alice has the app open on her phone and laptop, hitting two
different nodes. She closes the laptop at the same moment her phone
reconnects. Node A processes a LEAVE while node B processes a JOIN —
concurrently, with replication delay between them.

Kill the naive fixes one by one:
- Shared set in a database: every join/leave is now a write to a
  central store — latency, contention, and a single point of failure
  for something that changes hundreds of times a second.
- Timestamps + last-write-wins: clocks skew across nodes. The leave
  can carry a LATER timestamp than the join that actually happened
  after it → Alice is online but shows offline (ghosted), or the
  reverse (a phantom). Ordering by wall clock is fiction.
- Locks/consensus per update: correct and far too slow for presence
  churn. You'd pay Paxos prices for a status dot.

KEY LINE: "The problem isn't the data structure, it's that 'the set of
online users' has no single authoritative order of events. So we need
math that doesn't require one."

LIVE AID: presence-demo.html (this directory) — open it in a browser
tab beforehand; it's a single file, double-click works, no server.
Arrow keys step, 1/2/3 switch scenarios. Scenario 1 is EXACTLY the
Alice story above with the naive set — step through it while talking
instead of hand-waving. Scenario 2 is the node-crash phantom-users
case. STOP before scenario 3 — that's the payoff for the next slide.
-->

---

## Presence is a CRDT

- Add-wins observed-remove set with causal context
- Nodes that have seen the same events **agree — in any order**
- Conflict resolution without coordination, locks, or a database
- Phoenix-compatible `joins` / `leaves` diffs on the wire

<!--
Define CRDT without the acronym soup: a data structure whose MERGE
operation is commutative, associative, and idempotent. Consequence:
replicas can apply updates in any order, duplicated, delayed — and
they still converge to the same value. No coordinator, no locks, no
"who wins" tiebreak at runtime. The convergence is a property of the
math, not of the network behaving.

Decode the name on the slide, one term at a time:
- OBSERVED-REMOVE: you can only remove entries you've actually seen.
  A leave can never cancel a join it didn't know about — that's what
  kills the ghost-user bug from the last slide.
- ADD-WINS: when a join and leave are truly concurrent — neither knew
  about the other — the tie breaks toward PRESENT. Right bias for
  presence: a user flickering online for an extra second is cosmetic;
  showing a connected user as offline is a bug.
- CAUSAL CONTEXT: vector-clock-style metadata that's how the structure
  KNOWS whether two events were concurrent or ordered. This is the
  bookkeeping that replaces timestamps.

Audience takeaway if they remember one sentence: "Any two nodes that
have seen the same events agree on who's present — regardless of the
order they saw them in."

LIVE AID: switch presence-demo.html to scenario 3 (press 3). It
replays the same wifi-blip story with tagged joins — the stale leave
arrives late and removes ONLY the tag it observed, and both nodes
converge with Alice online. The final step covers the crash case too
(origin-tagged entries dropped when the runtime reports a node down).
Seeing the same messages arrive in the same broken order and NOT break
is the whole argument, animated.

Implementation notes (brief): the CRDT comes from the `lattice_presence`
package — beryl wraps it in an OTP actor per node and replicates diffs
over PubSub. On the wire it emits Phoenix-compatible `presence_state` /
`presence_diff` (joins/leaves maps), so the Phoenix JS Presence class
renders beryl presence without modification.

LIKELY QUESTION: "Why not just track it in Postgres/Redis?" — answer:
presence is high-churn ephemeral state; a DB adds a round-trip and a
SPOF to every mouse-in/mouse-out, and STILL has the concurrent-update
problem — you've just moved where the conflict happens.
-->

---

## Architecture: one slide

```
WebSocket transport     beryl_mist  (swappable — public transport SPI)
        │
Wire codec              beryl/wire  (pluggable; ships Phoenix framing)
        │
Channels · Presence · Groups
        │
Coordinator             one OTP actor: routing, registry, heartbeats
        │
PubSub                  Erlang pg — the ONLY cross-node layer
```

<!--
Narrate it as THE LIFE OF ONE MESSAGE, top to bottom:
1. A WebSocket frame arrives at the TRANSPORT (beryl_mist). The
   transport knows sockets and bytes — nothing about channels.
2. The CODEC decodes the frame into a typed message: topic, event,
   payload, refs. Phoenix JSON framing by default; the codec is an
   interface, so custom framing is a swap, not a fork.
3. The COORDINATOR — one OTP actor per beryl instance — looks up which
   registered handler matches the topic pattern, tracks which sockets
   have joined what, and enforces heartbeats (dead-connection sweep).
4. Your CHANNEL handler runs: typed callbacks from the earlier slides.
5. If the handler broadcasts, PUBSUB fans it out over pg — including
   to subscribers on OTHER nodes — and each node's transports push to
   their local sockets.

Two sentences to deliver slowly, because they're the design thesis:
- "Everything above the bottom line is NODE-LOCAL. pg PubSub is the
  only thing that crosses machines — so scaling out is starting more
  nodes and clustering them. There's no shared state to migrate."
- "The transport talks to beryl only through a public SPI —
  `beryl/transport`. beryl_mist is a plug-in, not a marriage. A
  different HTTP server, or a non-WebSocket transport, implements the
  same contract." (This is why the repo split into two packages.)

LIKELY QUESTION: "Is the single coordinator actor a bottleneck?" —
fair question; answer honestly: it's a routing/registry actor, the
heavy per-connection work lives in per-socket processes, and it's
per-node (not per-cluster). Published benchmarks for exactly this
kind of thing are near the top of the post-1.0 roadmap.
-->

---

## Production ready?

**Built in:** per-IP connection caps · node-wide connection ceiling
token-bucket rate limits · same-origin WebSocket policy by default

**Still on you:** edge proxy with a frame-size limit
Erlang distribution trusts every cluster node — keep the cluster closed

> The API is stable — what's still accruing is production mileage.

<!--
Frame the slide: "Real-time endpoints are abuse magnets — every one is
an open TCP invitation. So beryl ships abuse controls in the box AND
documents exactly where they stop. I think the second half is the more
interesting part."

BUILT IN (config on the transport, name the real APIs):
- `with_max_connections_per_ip` — per-IP connection caps, plus a
  node-wide total connection ceiling (recent addition) so one node
  can't be socket-flooded past its capacity.
- `with_message_rate` — token-bucket rate limiting per socket; that's
  what tamed the cursor firehose in the demo.
- Origin checking defaults to SAME-ORIGIN — browsers happily open
  cross-site WebSockets, so this closes cross-site hijacking by
  default rather than by remembering to configure it.

STILL ON YOU — two boundaries, stated plainly:
1. Frame-size limits are enforced POST-ASSEMBLY: the transport buffers
   a complete frame before beryl measures it. A hostile client can
   declare a huge frame, or stream endless fragments, and balloon the
   buffer BEFORE the check runs. So in production you MUST cap frame
   size at an edge proxy (nginx/HAProxy/Envoy) — beryl's limit is
   defense-in-depth for processing cost, not a memory bound. The
   upstream fix (cap-before-buffer in mist/gramps) is tracked publicly.
2. Erlang distribution — the clustering from the pg slide — TRUSTS
   every peer completely. It's a clustering protocol, not a security
   boundary. A hostile node can inject any internal traffic. Closed
   cluster, strong cookie, TLS distribution; SECURITY.md walks through
   all of it.

WHY SAY ALL THIS IN AN INTERVIEW: most young libraries hand-wave
security. Writing down what the library does NOT protect against is a
feature — users can only defend boundaries they know exist. And repeat
the honest framing here, where it matters most: the API is locked;
what a young library lacks is production mileage, which is exactly why
these boundaries are written down instead of hand-waved.
-->

---

## Earde

### Earde is a community platform that combines the immediacy of live communication with the permanence and discoverability of forums.

Technical communities can chat in real time and turn the valuable parts of a conversation into durable, searchable discussions instead of losing them in the scroll.

They can also decide if their knowledge must be indexed by search engines or kept private.

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

Use aquamarine for a BEAM client, and use the office PhoenixJS client for JS

<!--
beryl is the SERVER half of a matched pair — quick tour of the boxes:
- `aquamarine` — the Gleam CLIENT runtime: join topics, receive
  broadcasts, presence-sync, from Gleam code. Server and client in one
  typed language.
- `roost` — pure Phoenix wire-protocol library: frame constants,
  encode/decode, reply helpers. No IO, no runtime — aquamarine builds
  on it.
- `gluegun` — the client-side WebSocket transport (aquamarine's
  counterpart to beryl_mist).
- `phoenix_channel_fixtures` — the piece worth dwelling on: a shared
  package of CANONICAL wire-format test data. beryl, aquamarine, and
  roost all run their codecs against the SAME fixtures in CI.

KEY LINE: "Wire protocols drift when each side tests against its own
assumptions. Shared conformance fixtures make the server and client
dialects provably the same — if one drifts, a build goes red."

And the pragmatic escape hatch, worth repeating: you don't need any of
the client-side stack — the standard Phoenix JavaScript client works
against beryl as-is, presence included. Gleam on the server, phoenix.js
in the browser is a perfectly good day-one setup.
-->

---

<!-- _class: lead -->

## Try it, argue with me about it

`gleam add beryl beryl_mist`

(`beryl_ewe` coming soon!)

**Docs** — [beryl.tylerbutler.com](https://beryl.tylerbutler.com)
**Discuss** — [earde.com/c/beryl/s/general](https://earde.com/c/beryl/s/general)
**Chat** — the Gleam Discord · you'll find me there
**Source** — [github.com/tylerbutler/beryl](https://github.com/tylerbutler/beryl)

<!--
CLOSE — three beats:
1. Recap in one breath: "The BEAM already solved real-time's hard
   problems — cheap processes, supervision, clustering. Gleam adds the
   type system. beryl is just those two things pointed at channels."
2. The honest ask: the API is stable and 1.0 is here (or days away) —
   what shapes the roadmap now is real-world reports. The most useful
   thing anyone here can do is build something small with it and tell
   me where it hurt.
   Concrete on-ramp: clone the repo, run `examples/cursors`, read the
   Quick Start.
3. Where to find me: the earde space (link on screen) is the home for
   longer-form discussion — design questions, proposals, show-and-tell.
   For quick questions I'm in the Gleam Discord. Issues and PRs on
   GitHub always welcome.

Leave this slide up during Q&A — it's the one with all the links.

LIKELY Q&A NOT COVERED BY EARLIER NOTES:
- "Production users?" — be straight: the library is young and early
  adopters are the audience right now; the examples and conformance
  suites are the current proof of behavior.
- "What's next after 1.0?" — benchmarks, hardening the transport-memory
  story upstream (frame caps before buffering), and whatever the first
  wave of production feedback surfaces.
- "Does it work with Elixir/Phoenix apps?" — same wire protocol, so
  Phoenix CLIENTS work with beryl servers; it's a Gleam server library,
  not a Phoenix replacement inside an Elixir app.
-->
