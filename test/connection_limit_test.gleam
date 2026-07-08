//// Per-IP connection limit enforcement tests.
////
//// These exercise the public transport-facing API
//// (`beryl.acquire_connection_slot` / `beryl.release_connection_slot`) which
//// the Mist transport uses to admit or reject WebSocket upgrades based on the
//// real socket peer IP.

import beryl
import beryl/wire
import gleam/option.{None, Some}
import gleeunit/should

fn start_with_limit(max_connections: Int) -> beryl.Channels {
  let assert Ok(channels) =
    beryl.start(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_connections_per_ip(max_connections: max_connections),
    )
  channels
}

// A limit of 0 means unlimited: every acquire from the same IP succeeds and no
// permit is handed back (there is nothing to release).
pub fn zero_means_unlimited_test() {
  let channels = start_with_limit(0)

  beryl.acquire_connection_slot(channels, "1.2.3.4")
  |> should.equal(Ok(None))
  beryl.acquire_connection_slot(channels, "1.2.3.4")
  |> should.equal(Ok(None))
  beryl.acquire_connection_slot(channels, "1.2.3.4")
  |> should.equal(Ok(None))

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

// Releasing an unlimited (`None`) permit is a harmless no-op.
pub fn releasing_none_permit_is_noop_test() {
  beryl.release_connection_slot(None)
  |> should.equal(Nil)
}

// A permit obtained under a limit can be released explicitly.
pub fn some_permit_can_be_released_test() {
  let channels = start_with_limit(1)

  let assert Ok(permit) = beryl.acquire_connection_slot(channels, "10.0.0.6")
  case permit {
    Some(_) -> Nil
    None -> should.fail()
  }
  beryl.release_connection_slot(permit)

  beryl.stop(channels)
}
