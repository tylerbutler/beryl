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
import test_helper

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

// Acquisition immediately belongs to its requester. A process that dies
// before binding the permit to a WebSocket process cannot leak the slot.
pub fn slot_reclaimed_when_requester_dies_before_bind_test() -> Nil {
  let channels = start_with_limit(1)

  let acquired = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let assert Ok(_permit) =
        transport.acquire_connection_slot(channels, "10.0.0.7")
      process.send(acquired, Nil)
    })
  let assert Ok(Nil) = process.receive(acquired, 500)

  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.7") {
        Ok(permit) -> {
          transport.release_connection_slot(permit)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )
  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

// A timed-out request sends a cancellation behind its queued acquire. When
// the limiter resumes, it cannot leave a reservation without a caller.
pub fn timed_out_queued_acquire_is_cancelled_test() -> Nil {
  let channels = start_with_limit(1)
  let assert Ok(limiter) = beryl.app_limiter_pid(channels)
  test_helper.suspend_process(limiter)

  let outcome = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let exit = process.new_subject()
      process.send(outcome, #(
        transport.acquire_connection_slot(channels, "10.0.0.8"),
        exit,
      ))
      let assert Ok(Nil) = process.receive(exit, 2000)
    })
  let assert Ok(#(Error(Nil), exit)) = process.receive(outcome, 500)

  test_helper.resume_process(limiter)
  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.8") {
        Ok(permit) -> {
          transport.release_connection_slot(permit)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )
  process.send(exit, Nil)

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn transfer_tracks_new_owner_until_it_dies_test() -> Nil {
  let channels = start_with_limit(1)
  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "10.0.0.10")
  let bound = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let exit = process.new_subject()
      process.send(bound, #(transport.bind_connection_slot(permit), exit))
      let assert Ok(Nil) = process.receive(exit, 30_000)
    })
  let assert Ok(#(Ok(Nil), exit)) = process.receive(bound, 500)

  transport.acquire_connection_slot(channels, "10.0.0.10")
  |> should.be_error
  process.send(exit, Nil)
  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.10") {
        Ok(next) -> {
          transport.release_connection_slot(next)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn transfer_fails_after_request_owner_dies_test() -> Nil {
  let channels = start_with_limit(1)
  let acquired = process.new_subject()
  let _requester =
    process.spawn_unlinked(fn() {
      let assert Ok(permit) =
        transport.acquire_connection_slot(channels, "10.0.0.11")
      process.send(acquired, permit)
    })
  let assert Ok(permit) = process.receive(acquired, 500)

  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.11") {
        Ok(next) -> {
          transport.release_connection_slot(next)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )
  transport.bind_connection_slot(permit) |> should.be_error

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn cancellation_survives_limiter_restart_test() -> Nil {
  let channels = start_with_limit(1)
  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "10.0.0.12")
  let assert Ok(old_limiter) = beryl.app_limiter_pid(channels)

  process.kill(old_limiter)
  transport.release_connection_slot(permit)
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(channels) {
        Ok(limiter) -> limiter != old_limiter
        Error(Nil) -> False
      }
    },
    1000,
    10,
  )
  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.12") {
        Ok(next) -> {
          transport.release_connection_slot(next)
          True
        }
        Error(Nil) -> False
      }
    },
    500,
    10,
  )

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

pub fn duplicate_release_does_not_free_another_reservation_test() -> Nil {
  let channels = start_with_limit(2)
  let assert Ok(first) = transport.acquire_connection_slot(channels, "10.0.0.9")
  let assert Ok(second) =
    transport.acquire_connection_slot(channels, "10.0.0.9")

  transport.release_connection_slot(first)
  transport.release_connection_slot(first)
  let assert Ok(third) = transport.acquire_connection_slot(channels, "10.0.0.9")
  transport.acquire_connection_slot(channels, "10.0.0.9")
  |> should.be_error

  transport.release_connection_slot(second)
  transport.release_connection_slot(third)
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
