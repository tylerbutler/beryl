//// Node-wide (global) connection ceiling enforcement tests.
////
//// These exercise the same public transport-facing API
//// (`beryl.acquire_connection_slot` / `beryl.bind_connection_slot` /
//// `beryl.release_connection_slot`) the Mist transport uses, but focus on the
//// node-wide ceiling configured with `beryl.with_max_connections` — the limit
//// that bounds concurrent connections across *all* source IPs, which a per-IP
//// limit alone cannot enforce against distributed/rotating addresses.

import beryl
import beryl/event
import beryl/wire
import gleam/erlang/process
import gleam/int
import gleam/list
import gleeunit/should

fn start_trivial_app(
  config: beryl.Config,
) -> Result(beryl.Channels, beryl.StartError) {
  beryl.start_app(
    config,
    init: fn(_info: event.ConnectInfo(Nil)) { #(Nil, []) },
    update: fn(model, _ev) { event.Next(model, []) },
  )
}

// Build the list [1, 2, ..., n] without depending on a specific stdlib
// `list.range` availability.
fn seq(n: Int) -> List(Int) {
  seq_loop(n, [])
}

fn seq_loop(n: Int, acc: List(Int)) -> List(Int) {
  case n <= 0 {
    True -> acc
    False -> seq_loop(n - 1, [n, ..acc])
  }
}

fn start_with_global_limit(max_connections: Int) -> beryl.Channels {
  let assert Ok(channels) =
    start_trivial_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_connections(max_connections: max_connections),
    )
  channels
}

fn start_with_both_limits(
  max_per_ip: Int,
  max_connections: Int,
) -> beryl.Channels {
  let assert Ok(channels) =
    start_trivial_app(
      beryl.config(wire.phoenix_codec())
      |> beryl.with_max_connections_per_ip(max_connections: max_per_ip)
      |> beryl.with_max_connections(max_connections: max_connections),
    )
  channels
}

// A global limit of 0 means unlimited: acquisitions from many distinct IPs all
// succeed, and releasing a placeholder permit is a harmless no-op.
pub fn global_zero_means_unlimited_test() {
  let channels = start_with_global_limit(0)

  let assert Ok(first) = beryl.acquire_connection_slot(channels, "1.1.1.1")
  should.be_ok(beryl.acquire_connection_slot(channels, "2.2.2.2"))
  should.be_ok(beryl.acquire_connection_slot(channels, "3.3.3.3"))

  beryl.release_connection_slot(first)
  |> should.equal(Nil)

  beryl.stop(channels)
}

// Connections at or below the node-wide limit are admitted regardless of which
// IP they come from.
pub fn admits_connections_under_global_limit_test() {
  let channels = start_with_global_limit(3)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.1"))
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.2"))
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.0.3"))

  beryl.stop(channels)
}

// A connection that would exceed the node-wide limit is rejected even though it
// comes from a brand-new IP — this is the distributed-source case a per-IP
// limit cannot stop.
pub fn rejects_connection_over_global_limit_test() {
  let channels = start_with_global_limit(2)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.1.1"))
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.1.2"))

  // A third, unique source address is refused because the node is full.
  beryl.acquire_connection_slot(channels, "10.0.1.3")
  |> should.equal(Error(Nil))

  beryl.stop(channels)
}

// Releasing a slot frees node-wide capacity so a subsequent connection (from
// any IP) succeeds. Guards against global-slot leaks on normal close.
pub fn releasing_slot_frees_global_capacity_test() {
  let channels = start_with_global_limit(1)

  let assert Ok(permit) = beryl.acquire_connection_slot(channels, "10.0.2.1")
  // The node is at its ceiling now.
  beryl.acquire_connection_slot(channels, "10.0.2.2")
  |> should.equal(Error(Nil))

  // Freeing the slot admits the next connection from a different IP.
  beryl.release_connection_slot(permit)
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.2.2"))

  beryl.stop(channels)
}

// A global slot is reclaimed when its holder process dies without releasing —
// crashed handlers, transport failures, and heartbeat evictions all surface as
// the holder process exiting, so the monitor path must free node-wide capacity.
pub fn global_slot_reclaimed_when_holder_dies_without_release_test() {
  let channels = start_with_global_limit(1)

  let acquired = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let assert Ok(permit) =
        beryl.acquire_connection_slot(channels, "10.0.3.1")
      beryl.bind_connection_slot(permit)
      process.send(acquired, Nil)
      // Return immediately: the process exits without releasing, which must
      // still free the node-wide slot via the limiter's monitor.
    })
  let assert Ok(Nil) = process.receive(acquired, 500)

  // Give the limiter time to observe the holder's exit.
  process.sleep(50)

  // The reclaimed slot admits a connection from a *different* IP, proving the
  // global count (not just the per-IP count) was decremented.
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.3.2"))
  beryl.stop(channels)
}

// The per-IP and node-wide ceilings compose: a connection must be under both.
// Here the node-wide ceiling refuses a second IP even though that IP is under
// its own per-IP limit.
pub fn per_ip_and_global_compose_test() {
  // Per-IP allows 5 each, but the node as a whole allows only 1.
  let channels = start_with_both_limits(5, 1)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.4.1"))
  // Different IP, well under its per-IP limit, but the node is full.
  beryl.acquire_connection_slot(channels, "10.0.4.2")
  |> should.equal(Error(Nil))

  beryl.stop(channels)
}

// The per-IP limit still bites under a generous node-wide ceiling: a single IP
// cannot exceed its per-IP allotment even when the node has global room.
pub fn per_ip_limit_still_enforced_under_global_test() {
  let channels = start_with_both_limits(1, 10)

  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.5.1"))
  // Same IP is at its per-IP limit even though the node has room.
  beryl.acquire_connection_slot(channels, "10.0.5.1")
  |> should.equal(Error(Nil))
  // A different IP is admitted (node still under its global ceiling).
  should.be_ok(beryl.acquire_connection_slot(channels, "10.0.5.2"))

  beryl.stop(channels)
}

// Concurrent opens cannot race past the node-wide ceiling. Many processes
// attempt to acquire at once; because the check-and-increment is serialized
// inside the limiter actor, exactly `ceiling` of them succeed.
pub fn concurrent_opens_do_not_exceed_global_ceiling_test() {
  let ceiling = 5
  let attempts = 40
  let channels = start_with_global_limit(ceiling)

  let results = process.new_subject()
  seq(attempts)
  |> list.each(fn(i) {
    process.spawn_unlinked(fn() {
      // Each attempt uses a unique IP so per-IP tracking cannot be what caps
      // the total — only the node-wide ceiling can.
      let ip = "10.9." <> int.to_string(i) <> ".1"
      let outcome = case beryl.acquire_connection_slot(channels, ip) {
        Ok(permit) -> {
          beryl.bind_connection_slot(permit)
          True
        }
        Error(Nil) -> False
      }
      process.send(results, outcome)
      // Stay alive holding the slot until the test has finished counting, so
      // no slot is released and reused mid-count (which would let more than
      // `ceiling` acquisitions succeed over the test's lifetime).
      process.sleep(2000)
    })
    Nil
  })

  let successes =
    seq(attempts)
    |> list.fold(0, fn(acc, _) {
      case process.receive(results, 1000) {
        Ok(True) -> acc + 1
        Ok(False) -> acc
        Error(Nil) -> acc
      }
    })

  successes
  |> should.equal(ceiling)

  beryl.stop(channels)
}
