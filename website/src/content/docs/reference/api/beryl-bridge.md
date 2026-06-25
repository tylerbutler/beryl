---
title: beryl/bridge
description: Bridge - Forward an external OTP actor's message stream to a socket channel.
---

Bridge - Forward an external OTP actor's message stream to a socket channel.

 A common pattern is a long-lived domain actor (e.g. a per-document session)
 that emits updates which need to be pushed to each joined socket. Wiring
 this up by hand requires per-socket boilerplate: spawn a forwarder process
 holding a `Subject`, subscribe it to the domain actor, translate each
 message and call `beryl.send_info`, then tear the process down on
 `terminate`.

 `bridge` packages that plumbing into a single helper. Start a bridge inside
 a channel `join`, store the handle in the socket assigns, subscribe the
 returned `Subject` to your domain actor, and stop the bridge in `terminate`.
 The forwarder also monitors the owning channel process, so it is cleaned up
 automatically if that process dies — no leaked processes.

 ## Example

 ```gleam
 import beryl
 import beryl/bridge.{type Bridge}
 import beryl/channel
 import beryl/socket

 // Messages emitted by your domain actor.
 pub type DocEvent {
   Updated(version: Int)
 }

 pub type Assigns {
   Assigns(bridge: Bridge(DocEvent))
 }

 fn join(registered_channel, doc_actor, topic, _payload, socket) {
   // Forward each DocEvent to this socket's `handle_info` callback.
   let b =
     bridge.start(
       channel: registered_channel,
       socket_id: socket.id(socket),
       topic: topic,
       with: fn(event) { event },
     )
   // Subscribe the domain actor to the bridge's subject.
   doc.subscribe(doc_actor, bridge.subject(b))
   channel.JoinOk(reply: None, socket: socket.set_assigns(socket, Assigns(b)))
 }

 fn terminate(_reason, socket) {
   bridge.stop(socket.get_assigns(socket).bridge)
 }
 ```

## Types

### `Bridge`

A handle to a running bridge forwarder process.

 `message` is the type emitted by the external actor and received on the
 bridge's `Subject`. Obtain that subject with `subject` to wire it up to a
 domain actor, and call `stop` to tear the forwarder down.

```gleam
pub type Bridge(a)
```

## Functions

### `pid`

The forwarder process id.

 Exposed for diagnostics and supervision; you normally only need `subject`
 and `stop`.

```gleam
pub fn pid(Bridge(a)) -> process.Pid
```

### `start`

Start a bridge that forwards values from an external `Subject` to a socket's
 channel as `handle_info` messages.

 The returned `Bridge` owns a freshly spawned forwarder process. Pass
 `subject(bridge)` to the external/domain actor so it delivers its stream to
 the forwarder; each received value is mapped with `transform` and delivered
 via `beryl.send_info(channel, socket_id, topic, transform(value))`.

 Use `transform` to translate the domain message into whatever your channel's
 `handle_info` expects. If no translation is needed, pass the identity
 function `fn(value) { value }`.

 The forwarder monitors the calling (channel) process and exits if it dies,
 so a missed `stop` will not leak a process. Always call `stop` from your
 channel's `terminate` for prompt, deterministic cleanup.

```gleam
pub fn start(
  channel: beryl.RegisteredChannel(a, b),
  socket_id: String,
  topic: String,
  with: fn(c) -> b
) -> Bridge(c)
```

### `stop`

Stop the bridge's forwarder process.

 Call this from your channel's `terminate` callback. It is safe to call more
 than once and after the forwarder has already exited.

```gleam
pub fn stop(Bridge(a)) -> Nil
```

### `subject`

The `Subject` the external actor should send its stream to.

 Hand this to your domain actor (e.g. as its subscriber) so each emitted
 value is forwarded to the bridged socket/topic.

```gleam
pub fn subject(Bridge(a)) -> process.Subject(a)
```
