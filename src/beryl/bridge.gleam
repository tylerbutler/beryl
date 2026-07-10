//// Bridge - Forward an external OTP actor's message stream to a socket channel.
////
//// A common pattern is a long-lived domain actor (e.g. a per-document session)
//// that emits updates which need to be pushed to each joined socket. Wiring
//// this up by hand requires per-socket boilerplate: spawn a forwarder process
//// holding a `Subject`, subscribe it to the domain actor, translate each
//// message and call `beryl.send_info`, then tear the process down on
//// `terminate`.
////
//// `bridge` packages that plumbing into a single helper. Start a bridge inside
//// a channel `join`, store the handle in the socket assigns, subscribe the
//// returned `Subject` to your domain actor, and stop the bridge in `terminate`.
////
//// Calling `stop` from `terminate` is **required** for cleanup: channels are
//// dispatched by a shared coordinator rather than one process per channel, so
//// the process the forwarder monitors is the coordinator itself — the monitor
//// is a backstop for coordinator death, not a per-channel lifecycle. A bridge
//// whose `stop` is never called keeps running until the coordinator exits.
////
//// ## Example
////
//// ```gleam
//// import beryl
//// import beryl/bridge.{type Bridge}
//// import beryl/channel
//// import beryl/socket
////
//// // Messages emitted by your domain actor.
//// pub type DocEvent {
////   Updated(version: Int)
//// }
////
//// pub type Assigns {
////   Assigns(bridge: Bridge(DocEvent))
//// }
////
//// fn join(registered_channel, doc_actor, topic, _payload, socket) {
////   // Forward each DocEvent to this socket's `handle_info` callback.
////   let b =
////     bridge.start(
////       channel: registered_channel,
////       socket_id: socket.id(socket),
////       topic: topic,
////       with: fn(event) { event },
////     )
////   // Subscribe the domain actor to the bridge's subject.
////   doc.subscribe(doc_actor, bridge.subject(b))
////   channel.JoinOk(reply: None, socket: socket.set_assigns(socket, Assigns(b)))
//// }
////
//// fn terminate(_reason, socket) {
////   bridge.stop(socket.get_assigns(socket).bridge)
//// }
//// ```

import beryl.{type RegisteredChannel}
import gleam/erlang/process.{type Pid, type Subject}

/// How long `start` waits for the forwarder process to report its subjects
/// before giving up. The handshake is local and effectively instant; the
/// timeout only guards against a forwarder that failed to spawn.
const handshake_timeout_ms = 5000

/// A handle to a running bridge forwarder process.
///
/// `message` is the type emitted by the external actor and received on the
/// bridge's `Subject`. Obtain that subject with `subject` to wire it up to a
/// domain actor, and call `stop` to tear the forwarder down.
pub opaque type Bridge(message) {
  Bridge(pid: Pid, subject: Subject(message), control: Subject(Control))
}

/// Internal control messages for the forwarder loop.
type Control {
  Stop
}

/// Unified event type selected by the forwarder loop.
type Event(message) {
  Forward(message)
  Stopped
  OwnerDown
}

/// Start a bridge that forwards values from an external `Subject` to a socket's
/// channel as `handle_info` messages.
///
/// The returned `Bridge` owns a freshly spawned forwarder process. Pass
/// `subject(bridge)` to the external/domain actor so it delivers its stream to
/// the forwarder; each received value is mapped with `transform` and delivered
/// via `beryl.send_info(channel, socket_id, topic, transform(value))`.
///
/// Use `transform` to translate the domain message into whatever your channel's
/// `handle_info` expects. If no translation is needed, pass the identity
/// function `fn(value) { value }`.
///
/// Always call `stop` from your channel's `terminate` — that is the only
/// per-channel cleanup. The forwarder also monitors the calling process, but
/// because channel callbacks run inside the shared coordinator, that monitor
/// fires only if the coordinator itself dies; it does not detect an
/// individual channel ending.
pub fn start(
  channel channel: RegisteredChannel(assigns, info),
  socket_id socket_id: String,
  topic topic: String,
  with transform: fn(message) -> info,
) -> Bridge(message) {
  let ready = process.new_subject()
  let owner = process.self()

  let pid =
    process.spawn_unlinked(fn() {
      // Subjects must be created in the process that receives on them, so the
      // forwarder makes them here and hands them back to the caller.
      let data = process.new_subject()
      let control = process.new_subject()
      let monitor = process.monitor(owner)

      let selector =
        process.new_selector()
        |> process.select_map(data, Forward)
        |> process.select_map(control, fn(_) { Stopped })
        |> process.select_specific_monitor(monitor, fn(_) { OwnerDown })

      process.send(ready, #(data, control))
      forward_loop(selector, channel, socket_id, topic, transform)
    })

  let assert Ok(#(data, control)) = process.receive(ready, handshake_timeout_ms)

  Bridge(pid: pid, subject: data, control: control)
}

fn forward_loop(
  selector: process.Selector(Event(message)),
  channel: RegisteredChannel(assigns, info),
  socket_id: String,
  topic: String,
  transform: fn(message) -> info,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Forward(value) -> {
      beryl.send_info(channel, socket_id, topic, transform(value))
      forward_loop(selector, channel, socket_id, topic, transform)
    }
    // `stop` was called, or the owning channel process went down — exit
    // normally so the forwarder is cleaned up.
    Stopped -> Nil
    OwnerDown -> Nil
  }
}

/// The `Subject` the external actor should send its stream to.
///
/// Hand this to your domain actor (e.g. as its subscriber) so each emitted
/// value is forwarded to the bridged socket/topic.
pub fn subject(bridge: Bridge(message)) -> Subject(message) {
  bridge.subject
}

/// The forwarder process id.
///
/// Exposed for diagnostics and supervision; you normally only need `subject`
/// and `stop`.
pub fn pid(bridge: Bridge(message)) -> Pid {
  bridge.pid
}

/// Stop the bridge's forwarder process.
///
/// Call this from your channel's `terminate` callback. It is safe to call more
/// than once and after the forwarder has already exited.
pub fn stop(bridge: Bridge(message)) -> Nil {
  process.send(bridge.control, Stop)
}
