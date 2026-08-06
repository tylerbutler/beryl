//// Bridge - Forward an external OTP actor's message stream to a socket via
//// its `Sender`.
////
//// A common pattern is a long-lived domain actor (e.g. a per-document
//// session) that emits updates which need to be pushed to a connected
//// socket. Wiring this up by hand requires per-socket boilerplate: spawn a
//// forwarder process holding a `Subject`, subscribe it to the domain actor,
//// translate each message and call `event.notify`, then tear the process
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
//// import beryl/event.{type ConnectInfo}
////
//// // Messages emitted by your domain actor.
//// pub type DocEvent {
////   Updated(version: Int)
//// }
////
//// // Your app's server-side message type, delivered to `update` as `Info`.
//// pub type Msg {
////   DocUpdated(version: Int)
//// }
////
//// fn init(info: ConnectInfo(Msg)) {
////   // Forward each DocEvent to this socket as an `Info(Msg)` event.
////   let assert Ok(b) =
////     bridge.start(to: info.self, with: fn(e: DocEvent) {
////       let Updated(v) = e
////       DocUpdated(v)
////     })
////   // Subscribe the domain actor to the bridge's subject.
////   doc.subscribe(doc_actor, bridge.subject(b))
////   #(Model(bridge: b), [])
//// }
////
//// // Stop the bridge when the socket closes (e.g. from a `Closed` event).
//// bridge.stop(model.bridge)
//// ```

import beryl/event.{type Sender}
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

/// Why a bridge failed to start.
pub type StartError {
  /// The forwarder process did not report its subjects within
  /// `handshake_timeout_ms` — it failed to spawn or start.
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

/// Start a bridge that forwards values from an external `Subject` to a
/// socket's `update` function as `Info` events.
///
/// The returned `Bridge` owns a freshly spawned forwarder process. Pass
/// `subject(bridge)` to the external/domain actor so it delivers its stream
/// to the forwarder; each received value is mapped with `transform` and
/// delivered via `event.notify(sender, transform(value))`.
///
/// Use `transform` to translate the domain message into your app's
/// server-side `msg` type (the `Info` payload). If no translation is needed,
/// pass the identity function `fn(value) { value }`.
///
/// Always call `stop` when the owning socket or topic ends — that is the
/// per-owner cleanup. The forwarder also monitors the calling process, but
/// that monitor is only a backstop: it fires if the owner dies without a
/// `stop`, not as a per-topic lifecycle.
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
      event.notify(sender, transform(value))
      forward_loop(selector, sender, transform)
    }
    // `stop` was called, or the owning process went down — exit normally so
    // the forwarder is cleaned up.
    Stopped -> Nil
    OwnerDown -> Nil
  }
}

/// The `Subject` the external actor should send its stream to.
///
/// Hand this to your domain actor (e.g. as its subscriber) so each emitted
/// value is forwarded to the bridged socket.
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
/// Call this when the owning socket or topic ends. It is safe to call more
/// than once and after the forwarder has already exited.
pub fn stop(bridge: Bridge(message)) -> Nil {
  process.send(bridge.control, Stop)
}
