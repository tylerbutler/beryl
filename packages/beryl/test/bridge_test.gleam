import beryl/bridge
import beryl/socket
import gleam/erlang/process
import gleam/string
import gleeunit/should
import test_helper

/// Build a test `Sender` that forwards every notified value to a subject the
/// test can receive on, standing in for a socket's real `update` delivery.
fn capturing_sender(
  into received: process.Subject(message),
) -> socket.Sender(message) {
  socket.make_sender(fn(message) { process.send(received, message) })
}

pub fn bridge_forwards_subject_values_to_sender_test() -> Nil {
  let received = process.new_subject()
  let sender = capturing_sender(into: received)

  // Bridge an external stream (here, a plain Subject standing in for a domain
  // actor) to this sender, translating each value before forwarding.
  let assert Ok(started) =
    bridge.start(to: sender, with: fn(n: Int) { "tick-" <> string.inspect(n) })

  process.send(bridge.subject(started), 1)
  let assert Ok(msg1) = process.receive(received, 500)
  msg1 |> should.equal("tick-1")

  // A second value is forwarded too — the forwarder loops.
  process.send(bridge.subject(started), 2)
  let assert Ok(msg2) = process.receive(received, 500)
  msg2 |> should.equal("tick-2")

  bridge.stop(started)
}

pub fn bridge_stop_tears_down_forwarder_test() -> Nil {
  let received = process.new_subject()
  let assert Ok(started) =
    bridge.start(to: capturing_sender(into: received), with: fn(x: String) { x })

  let pid = bridge.pid(started)
  process.is_alive(pid) |> should.be_true

  bridge.stop(started)

  test_helper.wait_until(fn() { !process.is_alive(pid) }, 1000, 10)
  process.is_alive(pid) |> should.be_false
}

pub fn bridge_cleans_up_when_owner_dies_test() -> Nil {
  let received = process.new_subject()
  let pid_back = process.new_subject()

  // Start the bridge from a short-lived owner process. When that process
  // exits, the monitored forwarder should exit too — no leak even without an
  // explicit stop.
  process.spawn_unlinked(fn() {
    let assert Ok(started) =
      bridge.start(to: capturing_sender(into: received), with: fn(x: String) {
        x
      })
    process.send(pid_back, bridge.pid(started))
  })

  let assert Ok(forwarder) = process.receive(pid_back, 1000)

  test_helper.wait_until(fn() { !process.is_alive(forwarder) }, 1000, 10)
  process.is_alive(forwarder) |> should.be_false
}
