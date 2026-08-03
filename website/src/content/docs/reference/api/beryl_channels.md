---
title: beryl_channels
description: Composable channels for beryl real-time sockets.
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
 import beryl_channels
 import beryl_channels/channel

 pub fn handlers() -> List(channel.Handler) {
   [rooms.channel(), documents.channel()]
 }

 pub fn main() {
   let assert Ok(Nil) = beryl_channels.validate_handlers(handlers())
 }
 ```

 ## Routing rules

 Handlers are consulted in list order and the first pattern that
 matches a topic owns it, so more specific patterns belong earlier in
 the list. Overlapping patterns are allowed on purpose — `"room:lobby"`
 ahead of `"room:*"` is the normal way to special-case one topic. Two
 handlers registered with the *same* pattern string are rejected
 instead, because the second one could never be reached.

 ## Status

 The handler surface, the error surface, and the validation below are
 complete. The socket entry points that start a system from a handler
 table (`start` and `child_spec`, delegating to `beryl.start` and
 `beryl.child_spec`) land together with the event router; they are
 deliberately absent rather than present and inert.

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
    reason: String
  )
  DuplicatePattern(pattern: String)
}
```

#### Constructors

##### `InvalidPattern(
  pattern: String,
  reason: String
)`

A handler used a pattern string that is not a valid topic pattern.
 `pattern` is the offending pattern and `reason` describes the
 problem.

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
