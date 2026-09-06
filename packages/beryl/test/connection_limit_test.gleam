//// Per-IP connection limit enforcement tests.
////
//// These exercise the public transport-facing API
//// (`transport.acquire_connection_slot` / `transport.release_connection_slot`)
//// which transports use to admit or reject WebSocket upgrades based on the
//// real socket peer IP.

import app_test_helper
import beryl
import beryl/socket
import beryl/transport
import beryl/wire
import gleam/erlang/process
import gleeunit/should

fn start_with_limit(max_connections: Int) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(max_connections: max_connections),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _event: socket.Input(Nil)) {
        socket.Next(model, [])
      },
    )
  channels
}

fn start_with_rate(
  per_second per_second: Int,
  burst burst: Int,
) -> beryl.Sockets {
  let assert Ok(channels) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_connection_rate_per_ip(
          per_second: per_second,
          burst: burst,
        ),
      init: fn(_info) { #(Nil, []) },
      update: fn(model: Nil, _event: socket.Input(Nil)) {
        socket.Next(model, [])
      },
    )
  channels
}

// A limit of 0 means unlimited: every acquire from the same IP succeeds, and
// releasing the placeholder permit is a harmless no-op.
pub fn zero_means_unlimited_test() -> Nil {
  let channels = start_with_limit(0)

  let assert Ok(first) = transport.acquire_connection_slot(channels, "1.2.3.4")
  should.be_ok(transport.acquire_connection_slot(channels, "1.2.3.4"))
  should.be_ok(transport.acquire_connection_slot(channels, "1.2.3.4"))

  transport.release_connection_slot(first)
  |> should.equal(Nil)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// Connections at or below the configured limit are admitted.
pub fn admits_connections_under_limit_test() -> Nil {
  let channels = start_with_limit(2)

  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.1"))
  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.1"))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// The connection that would exceed the limit is rejected.
pub fn rejects_connection_over_limit_test() -> Nil {
  let channels = start_with_limit(1)

  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.2"))
  transport.acquire_connection_slot(channels, "10.0.0.2")
  |> should.equal(Error(Nil))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// Releasing a slot frees capacity so a subsequent connection from that IP
// succeeds. This guards against slot leaks that would permanently exhaust an IP.
pub fn releasing_slot_frees_capacity_test() -> Nil {
  let channels = start_with_limit(1)

  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "10.0.0.3")
  // At the limit now.
  transport.acquire_connection_slot(channels, "10.0.0.3")
  |> should.equal(Error(Nil))

  // Freeing the slot admits the next connection from the same IP.
  transport.release_connection_slot(permit)
  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.3"))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// The limit is tracked independently per IP.
pub fn limit_is_per_ip_test() -> Nil {
  let channels = start_with_limit(1)

  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.4"))
  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.5"))

  // Each IP is independently at its limit now.
  transport.acquire_connection_slot(channels, "10.0.0.4")
  |> should.equal(Error(Nil))
  transport.acquire_connection_slot(channels, "10.0.0.5")
  |> should.equal(Error(Nil))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// A slot is reclaimed when its holder process dies without releasing —
// crashed connection handlers must not permanently exhaust an IP's slots.
pub fn slot_reclaimed_when_holder_dies_without_release_test() -> Nil {
  let channels = start_with_limit(1)

  let acquired = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let assert Ok(permit) =
        transport.acquire_connection_slot(channels, "10.0.0.7")
      transport.bind_connection_slot(permit)
      process.send(acquired, Nil)
    })
  let assert Ok(Nil) = process.receive(acquired, 500)

  // Give the limiter time to observe the holder's exit.
  process.sleep(50)

  should.be_ok(transport.acquire_connection_slot(channels, "10.0.0.7"))
  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// A permit obtained under a limit can be released explicitly.
pub fn permit_can_be_released_test() -> Nil {
  let channels = start_with_limit(1)

  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "10.0.0.6")
  transport.release_connection_slot(permit)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// Releasing and reconnecting does not refresh the IP's burst allowance. Other
// IPs have independent buckets, and the exhausted bucket refills over time.
pub fn connection_rate_survives_reconnect_test() -> Nil {
  let channels = start_with_rate(per_second: 1, burst: 1)

  let assert Ok(first) =
    transport.acquire_connection_slot(channels, "192.0.2.1")
  transport.release_connection_slot(first)

  transport.acquire_connection_slot(channels, "192.0.2.1")
  |> should.equal(Error(Nil))
  should.be_ok(transport.acquire_connection_slot(channels, "192.0.2.2"))

  process.sleep(1100)
  should.be_ok(transport.acquire_connection_slot(channels, "192.0.2.1"))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}
