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
Who I am, what beryl is in one sentence.
Honest framing: pre-1.0, API still moving, feedback welcome.
-->

---

## Real-time is a distributed-state problem

- Chat rooms · live cursors · presence dots · collaborative editing
- Thousands of connections — constantly joining, leaving, **crashing**
- Ephemeral shared state that has to stay consistent across all of them

<!--
Set up the shape of the problem before naming any technology.
The hard part isn't the WebSocket — it's coordinating who's connected,
who's in which room, and what everyone should see, while clients churn.
-->

---

## The usual answer: build a runtime yourself

- WebSocket server + Redis pub/sub + sticky sessions
- Hand-rolled heartbeats, reconnect logic, cleanup jobs
- The platform doesn't help — so you assemble one from parts

<!--
On most stacks the runtime gives you nothing for this, so every team
rebuilds the same machinery. Foreshadow: there's a 40-year-old runtime
that ships all of it.
-->

---

<!-- _class: divider -->

# Why the BEAM?

Erlang's virtual machine — built for telephone switches:
millions of concurrent conversations that must not drop.

<!--
100-level moment starts here. Three ideas, one slide each.
Audience needs zero Erlang background.
-->

---

## Processes: concurrency you don't ration

- Millions of tiny, isolated, share-nothing processes per node
- **One process per connection is the normal pattern**, not a hack
- No shared memory, no locks — processes only send messages
- A crash takes down one conversation, not the server

<!--
Contrast with OS threads / async runtimes: BEAM processes are ~KB each,
scheduled preemptively by the VM. Isolation is the point — one user's
bug can't corrupt another user's state.
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
This is why BEAM systems are famously boring in production.
beryl embeds into the host app's supervision tree via child_spec —
your channels recover along with everything else.
-->

---

## Distribution: clustering built into the runtime

- Nodes connect to each other; processes message across machines transparently
- `pg` process groups = distributed pub/sub, **in the standard library**
- No Redis. No message broker. No sidecar.

<!--
This is the punchline of the BEAM section: the thing everyone bolts on
with Redis is a stdlib primitive here. beryl's PubSub is a thin layer
over pg — and it's the ONLY cross-node piece of beryl.
-->

---

## Gleam: types on the BEAM

- Small, friendly, **statically typed** language compiling to Erlang
- Full OTP interop — actors, supervisors, `pg` all available
- The BEAM's superpowers, with a compiler watching your back

<!--
The classic newcomer objection to Erlang/Elixir is dynamic typing.
Gleam is the answer: sound type system, great errors, tiny surface.
This is the gap beryl lives in.
-->

---

## beryl ≈ Phoenix Channels, with a compiler

- **Channels** — topic handlers with wildcards: `room:*`, `document:*:*`
- **Presence** — who's online, CRDT-backed, works across nodes
- **PubSub** — distributed broadcast over `pg`
- **Groups** — named topic collections for multi-topic fan-out
- **Transport** — Mist WebSockets, Phoenix-compatible wire format

<!--
If they know Phoenix: same mental model, same wire protocol —
existing Phoenix JS clients connect unchanged.
If they don't: batteries-included real-time toolkit for Gleam.
Two packages: beryl (core) + beryl_mist (transport).
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
Walk it top to bottom: start the runtime with a codec, register a
handler against a topic pattern, compose WebSocket upgrade + normal
HTTP into one Mist handler. That's the entire server.
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
The core pitch in one snippet. Each channel defines its own assigns
type; join seeds it, every later callback receives it, and the
compiler catches mismatches. In Phoenix this is a runtime map.
Callbacks return NoReply / Reply / Push — plain values, not macros.
-->

---

<!-- _class: divider -->

# Demo: live cursors

`examples/cursors` — wildcards · presence · `broadcast_from` · rate limiting

<!--
Everyone's cursor live on one screen. Point out as it runs:
- each browser = one BEAM process
- broadcast_from = everyone but the sender
- presence list updates as tabs open/close
- rate limiter tames the mousemove firehose
Also in the repo: chatrooms (auth, groups), collab_docs (client CRDTs).
-->

---

## "Who's online?" is harder than it sounds

- Same user joins on node A and leaves on node B — **concurrently**
- Timestamps lie · locks don't scale · last-write-wins drops users
- Every naive approach ghosts someone or shows phantoms

<!--
Set up the problem before the acronym. Presence looks trivial on one
node and gets genuinely hard the moment there are two.
-->

---

## Presence is a CRDT

- Add-wins observed-remove set with causal context
- Nodes that have seen the same events **agree — in any order**
- Conflict resolution without coordination, locks, or a database
- Phoenix-compatible `joins` / `leaves` diffs on the wire

<!--
Don't teach CRDT internals — teach the guarantee: deterministic
convergence. "Add-wins" = concurrent join+leave resolves to present,
which is the right bias for presence. Backed by lattice_presence.
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
Two things to say out loud:
1. Everything is node-local except pg PubSub — that's why it scales.
2. Transport is an SPI: beryl_mist is a plug-in, not a marriage.
   Same for the codec — Phoenix framing is the default, not the law.
-->

---

## Honest about production

**Built in:** per-IP connection caps · node-wide connection ceiling
token-bucket rate limits · same-origin WebSocket policy by default

**Still on you:** edge proxy with a frame-size limit
Erlang distribution trusts every cluster node — keep the cluster closed

> Pre-1.0 — the API is still moving.

<!--
Differentiator: SECURITY.md spells out the threat model instead of
hand-waving. Frame limits are enforced post-assembly, so a proxy must
cap frame size at the edge. Good interview material: "what does the
library refuse to pretend it does for you?"
-->

---

## The ecosystem around it

```
phoenix_channel_fixtures ──── shared wire-format test data
        │                            │
      beryl (server) ◄── Phoenix wire ──► aquamarine (Gleam client)
        │                            │
   beryl_mist (WS)                roost · gluegun
```

- Server and client tested against the **same conformance fixtures**
- Or skip aquamarine entirely and use the Phoenix JS client

<!--
beryl is the server half of a matched pair. Shared fixtures keep the
wire dialects honest across packages — and Phoenix compatibility means
the huge existing Phoenix client ecosystem works out of the box.
-->

---

<!-- _class: lead -->

## Try it, argue with me about it

`gleam add beryl beryl_mist`

**Docs** — [beryl.tylerbutler.com](https://beryl.tylerbutler.com)
**Discuss** — [earde.com/c/beryl/s/general](https://earde.com/c/beryl/s/general)
**Chat** — the Gleam Discord · you'll find me there
**Source** — [github.com/tylerbutler/beryl](https://github.com/tylerbutler/beryl)

<!--
Close: pre-1.0, feedback actively shapes the API.
Point people at the earde space for longer-form discussion and the
Gleam Discord for quick questions.
-->
