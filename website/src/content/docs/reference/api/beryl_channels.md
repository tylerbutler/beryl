---
title: "beryl_channels"
description: "Composable channels for beryl real-time sockets."
---

Composable channels for beryl real-time sockets.

 This package layers Phoenix-shaped channel modules on top of beryl's
 public app-side dispatch API. An application registers a list of
 [`channel.Handler`](./beryl_channels/channel.html#Handler) values —
 each a topic pattern plus a typed `join` callback — and the layer
 routes every socket event to the channel that owns its topic. No
 hand-written message union and no hand-written router are required,
 and each channel keeps its own private state and server-side message
 type.

 ```gleam
 import beryl
 import beryl/wire
 import beryl_channels
 import beryl_channels/channel
 import gleam/json

 // `rooms` and `documents` are your own modules; each exports a
 // `channel()` returning a `channel.Handler`.
 pub fn handlers() -> List(channel.Handler) {
   [rooms.channel(), documents.channel()]
 }

 pub fn main() {
   let assert Ok(sockets) =
     beryl_channels.start(
       beryl.config(wire.phoenix_codec()),
       handlers: handlers(),
     )

   beryl.broadcast(sockets, "room:lobby", "announce", json.string("hi"))
 }
 ```

 The returned `beryl.Sockets` is an ordinary core handle: pass it to a
 transport (`beryl_mist`, `beryl_ewe`), to `beryl.broadcast`, and to
 `beryl.stop`.

 ## Routing rules

 Handlers are consulted in list order and the first pattern that
 matches a topic owns it, so more specific patterns belong earlier in
 the list. Overlapping patterns are allowed on purpose — `"room:lobby"`
 ahead of `"room:*"` is the normal way to special-case one topic. Two
 handlers registered with the *same* pattern string are rejected
 instead, because the second one could never be reached.

 A join for a topic no handler matches is refused explicitly, with the
 reason payload `{"reason": "unmatched topic"}`, rather than left
 unanswered.

## Types

### `ChildSpecError`

Why building a channel-system child specification failed.

 Like `beryl.child_spec`, this reports only the failures that can be
 detected before the supervision tree is started.

```gleam
pub type ChildSpecError {
  ChildSpecInvalidHandlers(HandlerError)
  ChildSpecInvalidConfig(beryl.ConfigError)
}
```

#### Constructors

##### `ChildSpecInvalidHandlers(HandlerError)`

The handler table failed validation, exactly as
 [`validate_handlers`](#validate_handlers) reports it.

##### `ChildSpecInvalidConfig(beryl.ConfigError)`

The `beryl.Config` failed the core's eager validation. The wrapped
 value is the core error exactly as `beryl.child_spec` returned it.

### `HandlerError`

Why a handler table was rejected.

 Validation is deterministic and two-phase: every pattern's syntax is
 checked in registration order first, then duplicate pattern strings are
 looked for in registration order. The first problem found in that order
 is the one reported.

```gleam
pub type HandlerError {
  InvalidPattern(
    pattern: String,
    reason: topic.TopicError
  )
  DuplicatePattern(pattern: String)
}
```

#### Constructors

##### `InvalidPattern(
  pattern: String,
  reason: topic.TopicError
)`

A handler used a pattern string that is not a valid topic pattern.
 `pattern` is the offending pattern and `reason` is the
 [`beryl/topic`](https://hexdocs.pm/beryl/beryl/topic.html) error
 nested rather than flattened to a string, so it stays matchable.

##### `DuplicatePattern(pattern: String)`

Two handlers were registered with the same pattern string. The
 second one could never receive a join, because routing takes the
 first match.

### `StartError`

Why starting a channel system failed.

 The beryl error is nested rather than flattened, so nothing the core
 reports is lost on the way through this layer.

```gleam
pub type StartError {
  InvalidHandlers(HandlerError)
  SocketStartFailed(beryl.StartError)
}
```

#### Constructors

##### `InvalidHandlers(HandlerError)`

The handler table failed validation. Reported before any process is
 started, and identical to what
 [`validate_handlers`](#validate_handlers) reports.

##### `SocketStartFailed(beryl.StartError)`

The underlying beryl system refused to start. The wrapped value is
 the core error exactly as `beryl.start` returned it.

## Functions

### `child_spec`

Build a channel system's supervision child specification, for
 embedding it in an application's own supervision tree instead of
 starting it standalone with [`start`](#start).

 Like `beryl.child_spec`, this reports only what can be detected before
 the tree is started: the handler table is validated first, then the
 `beryl.Config`, whose error is returned nested in
 [`ChildSpecInvalidConfig`](#ChildSpecError). The returned
 `beryl.Sockets` is usable as soon as the owning tree is running.

 ## Example

 ```gleam
 let assert Ok(#(sockets, spec)) =
   beryl_channels.child_spec(
     beryl.config(wire.phoenix_codec()),
     handlers: [rooms.channel()],
   )

 let assert Ok(_root) =
   static_supervisor.new(static_supervisor.OneForOne)
   |> static_supervisor.add(spec)
   |> static_supervisor.start()
 ```

```gleam
pub fn child_spec(
  beryl.Config,
  handlers: List(channel.Handler)
) -> Result(#(beryl.Sockets, supervision.ChildSpecification(static_supervisor.Supervisor)), ChildSpecError)
```

### `start`

Start a channel system: one beryl socket system that routes every
 event to the handler owning its topic.

 The handler table is validated first (see
 [`validate_handlers`](#validate_handlers)), so an unusable table is
 reported before any process is started. Only then is `beryl.start`
 called, with the handler table compiled into its `init`/`update` pair;
 its error is returned nested in
 [`SocketStartFailed`](#StartError).

 The returned handle is an ordinary `beryl.Sockets`: give it to a
 transport, to `beryl.broadcast`, and to `beryl.stop`.

 ## Example

 ```gleam
 let assert Ok(sockets) =
   beryl_channels.start(
     beryl.config(wire.phoenix_codec()),
     handlers: [rooms.channel()],
   )
 ```

```gleam
pub fn start(
  beryl.Config,
  handlers: List(channel.Handler)
) -> Result(beryl.Sockets, StartError)
```

### `validate_handlers`

Validate a handler table without starting anything.

 Checks, in registration order, that every pattern is a valid beryl
 topic pattern, then — again in registration order — that no pattern
 string is registered twice. Overlapping but non-identical patterns
 (`"room:lobby"` and `"room:*"`) are valid: routing resolves them by
 first match.

 The socket entry points run exactly this validation before starting
 anything, so a handler table that passes here is accepted there too.

```gleam
pub fn validate_handlers(List(channel.Handler)) -> Result(Nil, HandlerError)
```
