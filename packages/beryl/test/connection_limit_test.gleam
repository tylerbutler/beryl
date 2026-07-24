//// Per-IP connection limit enforcement tests.
////
//// These exercise the public transport-facing API
//// (`beryl.acquire_connection_slot` / `beryl.release_connection_slot`) which
//// the Mist transport uses to admit or reject WebSocket upgrades based on the
//// real socket peer IP.

import app_test_helpers as h
import beryl
import beryl/event
import beryl/wire
import gleam/erlang/process
import gleeunit/should

fn start_with_limit(max_connections: Int) -> beryl.Sockets {
  let assert Ok(channels) =
    h.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(max_connections: max_connections),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _ev: event.Input(Nil)) { event.Next(model, []) },
    )
  channels
}

// A limit of 0 means unlimited: every acquire from the same IP succeeds, and
// releasing the placeholder permit is a harmless no-op.
pub fn zero_means_unlimited_test() {
  let channels = start_with_limit(0)

  let assert Ok(first) = beryl.acquire_connection_slot(channels, "1.2.3.4")
  should.be_ok(beryl.acquire_connection_slot(channels, "1.2.3.4"))
  should.be_ok(beryl.acquire_connection_slot(channels, "1.2.3.4"))

  beryl.release_connection_slot(first)
  |> should.equal(Nil)

  beryl.stop(channels)
}

// Connections at or below the configured limit are admitted.
pub fn admits_connections_under_limit_test() {
  let channels = start_with_limit(2)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.1"))
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.1"))

  beryl.stop(channels)
}

// The connection that would exceed the limit is rejected.
pub fn rejects_connection_over_limit_test() {
  let channels = start_with_limit(1)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.2"))
  beryl.acquire_connection_slot(channels, "10.0.0.2")
  |> should.equal(Error(Nil))

  beryl.stop(channels)
}

// Releasing a slot frees capacity so a subsequent connection from that IP
// succeeds. This guards against slot leaks that would permanently exhaust an IP.
pub fn releasing_slot_frees_capacity_test() {
  let channels = start_with_limit(1)

  let assert Ok(permit) = beryl.acquire_connection_slot(channels, "10.0.0.3")
  // At the limit now.
  beryl.acquire_connection_slot(channels, "10.0.0.3")
  |> should.equal(Error(Nil))

  // Freeing the slot admits the next connection from the same IP.
  beryl.release_connection_slot(permit)
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.3"))

  beryl.stop(channels)
}

// The limit is tracked independently per IP.
pub fn limit_is_per_ip_test() {
  let channels = start_with_limit(1)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.4"))
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.5"))

  // Each IP is independently at its limit now.
  beryl.acquire_connection_slot(channels, "10.0.0.4")
  |> should.equal(Error(Nil))
  beryl.acquire_connection_slot(channels, "10.0.0.5")
  |> should.equal(Error(Nil))

  beryl.stop(channels)
}

// A slot is reclaimed when its holder process dies without releasing —
// crashed connection handlers must not permanently exhaust an IP's slots.
pub fn slot_reclaimed_when_holder_dies_without_release_test() {
  let channels = start_with_limit(1)

  let acquired = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let assert Ok(permit) =
        beryl.acquire_connection_slot(channels, "10.0.0.7")
      beryl.bind_connection_slot(permit)
      process.send(acquired, Nil)
    })
  let assert Ok(Nil) = process.receive(acquired, 500)

  // Give the limiter time to observe the holder's exit.
  process.sleep(50)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.7"))
  beryl.stop(channels)
}

// A permit obtained under a limit can be released explicitly.
pub fn permit_can_be_released_test() {
  let channels = start_with_limit(1)

  let assert Ok(permit) = beryl.acquire_connection_slot(channels, "10.0.0.6")
  beryl.release_connection_slot(permit)

  beryl.stop(channels)
}
