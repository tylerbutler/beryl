//// Bridge - Forward an external OTP actor's message stream to a socket via
//// its `Sender`.
////
//// A common pattern is a long-lived domain actor (e.g. a per-document
//// session) that emits updates which need to be pushed to a connected
//// socket. Wiring this up by hand requires per-socket boilerplate: spawn a
//// forwarder process holding a `Subject`, subscribe it to the domain actor,
//// translate each message and call `socket.notify`, then tear the process
//// down when the socket closes.
////
//// `bridge` packages that plumbing into a single helper. Start a bridge in
//// your app's `init` (or when a topic is joined), store the handle in the
//// socket model, subscribe the returned `Subject` to your domain actor, and
//// stop the bridge when the socket or topic closes.
////
//// Calling `stop` when the socket/topic ends is **required** for cleanup:
//// the forwarder monitors the process that started it only as a backstop for
//// that owner's death, not as a per-topic lifecycle. A bridge whose `stop`
//// is never called keeps running until its owner exits.
////
//// ## Example
////
//// ```gleam
//// import beryl/bridge.{type Bridge}
//// import beryl/socket.{type ConnectInfo}
////
//// // Messages emitted by your domain actor.
//// pub type DocEvent {
////   Updated(version: Int)
//// }
////
//// // Your app's server-side message type, delivered to `update` as `Info`.
//// pub type Message {
////   DocUpdated(version: Int)
//// }
////
//// fn init(info: ConnectInfo(Message)) -> #(Model, List(socket.Effect)) {
////   // Forward each DocEvent to this socket as an `Info(Message)` event.
////   let assert Ok(bridge_handle) =
////     bridge.start(to: info.self, with: fn(event: DocEvent) {
////       let Updated(version) = event
////       DocUpdated(version)
////     })
////   // Subscribe the domain actor to the bridge's subject.
////   doc.subscribe(doc_actor, bridge.subject(bridge_handle))
////   #(Model(bridge: bridge_handle), [])
//// }
////
//// // Stop the bridge when the socket closes (e.g. from a `Closed` event).
//// bridge.stop(model.bridge)
//// ```

import beryl/socket.{type Sender}
import gleam/erlang/process.{type Pid, type Subject}

/// How long `start` waits for the forwarder process to report its subjects
/// before giving up. The handshake is local and effectively instant; the
/// timeout only guards against a forwarder that failed to spawn.
const handshake_timeout_ms = 5000

/// A handle to a running bridge forwarder.
///
/// `message` is the type that the external actor sends to the bridge's
/// `Subject`. Get the subject with `subject`. Call `stop` to stop the
/// forwarder.
pub opaque type Bridge(message) {
  Bridge(pid: Pid, subject: Subject(message), control: Subject(Control))
}

/// Why a bridge failed to start.
pub type StartError {
  /// The forwarder did not report its subjects within
  /// `handshake_timeout_ms`. It failed to spawn or start.
  ForwarderUnavailable
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

/// Start a bridge from an external `Subject` to a socket's `update` function.
///
/// The returned `Bridge` owns a new forwarder process. Pass `subject(bridge)`
/// to the external or domain actor. The forwarder maps each received value
/// with `transform` and sends it as an `Info` event through
/// `socket.notify(sender, transform(value))`.
///
/// Use `transform` to translate the domain message into your app's
/// server-side `message` type (the `Info` payload). If no translation is needed,
/// pass the identity function `fn(value) { value }`.
///
/// Always call `stop` when the owning socket or topic ends. The forwarder
/// also monitors the calling process. This monitor stops the forwarder if
/// the owner dies without calling `stop`, but it does not track topic
/// lifecycles.
pub fn start(
  to sender: Sender(info),
  with transform: fn(message) -> info,
) -> Result(Bridge(message), StartError) {
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
      forward_loop(selector, sender, transform)
    })

  case process.receive(ready, handshake_timeout_ms) {
    Ok(#(data, control)) ->
      Ok(Bridge(pid: pid, subject: data, control: control))
    Error(Nil) -> Error(ForwarderUnavailable)
  }
}

fn forward_loop(
  selector: process.Selector(Event(message)),
  sender: Sender(info),
  transform: fn(message) -> info,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Forward(value) -> {
      socket.notify(sender, transform(value))
      forward_loop(selector, sender, transform)
    }
    // `stop` was called, or the owning process went down — exit normally so
    // the forwarder is cleaned up.
    Stopped -> Nil
    OwnerDown -> Nil
  }
}

/// Return the `Subject` that receives the external actor's stream.
///
/// Give this subject to the domain actor, for example as its subscriber.
/// Each value is then sent to the bridged socket.
pub fn subject(bridge: Bridge(message)) -> Subject(message) {
  bridge.subject
}

/// Return the forwarder process ID.
///
/// Use this value for diagnostics and supervision. Most callers need only
/// `subject` and `stop`.
pub fn pid(bridge: Bridge(message)) -> Pid {
  bridge.pid
}

/// Stop the bridge's forwarder.
///
/// Call this when the owning socket or topic ends. It is safe to call more
/// than once and after the forwarder has already exited.
pub fn stop(bridge: Bridge(message)) -> Nil {
  process.send(bridge.control, Stop)
}
