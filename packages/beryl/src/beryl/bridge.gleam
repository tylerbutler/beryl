//// Forward an external OTP actor's message stream to a socket through its
//// `Sender`.
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

import beryl/internal
import beryl/log
import beryl/overload
import beryl/socket.{type Sender}
import gleam/erlang/process.{type Pid, type Subject}

/// How long `start` waits for the forwarder process to report its subjects
/// before giving up. The handshake is local and effectively instant; the
/// timeout guards against a forwarder that failed to spawn or stalled before
/// readiness.
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
  /// `handshake_timeout_ms`. It failed to spawn or reach readiness, and any
  /// timed-out child is cleaned up before `start` returns.
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
  start_with_handshake(
    to: sender,
    with: transform,
    handshake_timeout_ms: handshake_timeout_ms,
    before_ready: fn() { Nil },
  )
}

@internal
pub fn start_with_handshake(
  to sender: Sender(info),
  with transform: fn(message) -> info,
  handshake_timeout_ms handshake_timeout_ms: Int,
  before_ready before_ready: fn() -> Nil,
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

      before_ready()
      process.send(ready, #(data, control))
      forward_loop(selector, sender, transform)
    })
  let startup_monitor = process.monitor(pid)

  case process.receive(ready, handshake_timeout_ms) {
    Ok(#(data, control)) -> {
      let demonitor_result = process.demonitor_process(startup_monitor)
      let _demonitor_result = demonitor_result
      Ok(Bridge(pid: pid, subject: data, control: control))
    }
    Error(Nil) -> {
      cleanup_timed_out_startup(
        pid: pid,
        ready: ready,
        startup_monitor: startup_monitor,
      )
      Error(ForwarderUnavailable)
    }
  }
}

fn cleanup_timed_out_startup(
  pid pid: Pid,
  ready ready: Subject(#(Subject(message), Subject(Control))),
  startup_monitor startup_monitor: process.Monitor,
) -> Nil {
  process.kill(pid)
  let _down =
    process.new_selector()
    |> process.select_specific_monitor(startup_monitor, fn(down) { down })
    |> process.selector_receive_forever
  let demonitor_result = process.demonitor_process(startup_monitor)
  let _demonitor_result = demonitor_result
  drain_ready(ready)
}

fn drain_ready(ready: Subject(message)) -> Nil {
  case process.receive(ready, 0) {
    Ok(_) -> drain_ready(ready)
    Error(Nil) -> Nil
  }
}

fn forward_loop(
  selector: process.Selector(Event(message)),
  sender: Sender(info),
  transform: fn(message) -> info,
) -> Nil {
  case process.selector_receive_forever(selector) {
    Forward(value) -> {
      case socket.notify(sender, transform(value)) {
        Ok(Nil) -> forward_loop(selector, sender, transform)
        Error(error) ->
          log.warn(
            internal.logger("beryl.bridge"),
            "Bridge stopped: target rejected work",
            [
              #("reason", overload.describe(error)),
            ],
          )
      }
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
