//// Pending work bounds are independent of the global and per-IP holder limits.

import app_test_helper
import beryl
import beryl/connection_limit
import beryl/overload
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option
import gleam/string
import gleeunit/should
import test_helper
import unitest

fn start(items: Int, bytes: Int) -> beryl.Sockets {
  let assert Ok(limits) = overload.limits(items: items, bytes: bytes)
  let assert Ok(sockets) =
    app_test_helper.start_app(
      beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections(2)
        |> beryl.with_max_connections_per_ip(1)
        |> beryl.with_connection_queue_limits(limits),
      init: fn(_) { #(Nil, []) },
      update: fn(model: Nil, _: socket.Input(Nil)) { socket.Next(model, []) },
    )
  sockets
}

fn occupancy(sockets: beryl.Sockets) -> overload.Occupancy {
  let assert option.Some(limiter) = beryl.configured_connection_limiter(sockets)
  let assert Ok(snapshot) = connection_limit.queue_snapshot(limiter)
  snapshot
}

fn wait_empty(sockets: beryl.Sockets) -> Nil {
  test_helper.wait_until(fn() { occupancy(sockets).items == 0 }, 1000, 1)
}

fn abandon_request(sockets: beryl.Sockets, expected_items: Int) -> Nil {
  let caller =
    process.spawn_unlinked(fn() {
      let _outcome = transport.acquire_connection_slot(sockets, "192.0.2.2")
    })
  test_helper.wait_until(
    fn() { occupancy(sockets).items == expected_items },
    500,
    1,
  )
  process.kill(caller)
  test_helper.wait_until(fn() { !process.is_alive(caller) }, 500, 1)
}

pub fn timed_out_work_and_cancellations_stay_bounded_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(6, 4096)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)

  list.each(list.repeat(Nil, 20), fn(_) {
    transport.acquire_connection_slot(sockets, "192.0.2.1")
    |> should.equal(Error(Nil))
  })
  let snapshot = occupancy(sockets)
  snapshot.items |> should.equal(6)
  snapshot.high_items |> should.equal(6)
  snapshot.rejected |> should.equal(17)
  should.be_true(snapshot.bytes <= snapshot.max_bytes)
  // Only a coalesced wake and one recovery timer can reach the stalled actor.
  should.be_true(test_helper.mailbox_length(limiter) <= 2)

  test_helper.resume_process(limiter)
  wait_empty(sockets)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  transport.release_connection_slot(permit)
  wait_empty(sockets)
  test_helper.mailbox_length(process.self()) |> should.equal(0)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn dead_pending_callers_cannot_strand_capacity_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(6, 4096)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)

  abandon_request(sockets, 2)
  abandon_request(sockets, 4)
  abandon_request(sockets, 6)
  list.each(list.repeat(Nil, 20), fn(_) {
    transport.acquire_connection_slot(sockets, "192.0.2.3")
    |> should.equal(Error(Nil))
  })
  let rejected =
    server.upgrade(
      request: request.new() |> request.set_path("/socket"),
      sockets: sockets,
      config: server.default_config("/socket"),
      telemetry: transport.telemetry(sockets, transport.Mist),
      request_ip: fn(_) { Ok("192.0.2.3") },
      reject: response.new,
      accept: fn(_, permit) {
        transport.release_connection_slot(permit)
        response.new(101)
      },
      next: fn() { response.new(404) },
    )
  rejected.status |> should.equal(429)
  occupancy(sockets).items |> should.equal(6)
  should.be_true(test_helper.mailbox_length(limiter) <= 2)

  test_helper.resume_process(limiter)
  wait_empty(sockets)
  let assert Ok(first) = transport.acquire_connection_slot(sockets, "192.0.2.2")
  let assert Ok(second) =
    transport.acquire_connection_slot(sockets, "192.0.2.3")
  transport.acquire_connection_slot(sockets, "192.0.2.4")
  |> should.equal(Error(Nil))
  transport.release_connection_slot(first)
  transport.release_connection_slot(second)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn completion_is_reclaimed_if_granted_caller_dies_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(4, 4096)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)
  let caller =
    process.spawn_unlinked(fn() {
      let _outcome = transport.acquire_connection_slot(sockets, "192.0.2.1")
    })
  test_helper.wait_until(fn() { occupancy(sockets).items == 2 }, 500, 1)
  test_helper.suspend_process(caller)
  test_helper.resume_process(limiter)
  // The reply is buffered in the suspended caller. Only its completion remains.
  test_helper.wait_until(fn() { occupancy(sockets).items == 1 }, 500, 1)
  process.kill(caller)
  wait_empty(sockets)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  transport.release_connection_slot(permit)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn release_bypasses_saturation_and_is_coalesced_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(4, 4096)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  wait_empty(sockets)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)
  abandon_request(sockets, 2)
  abandon_request(sockets, 4)
  transport.bind_connection_slot(permit) |> should.equal(Error(Nil))
  list.each(list.repeat(Nil, 20), fn(_) {
    transport.release_connection_slot(permit)
  })
  should.be_true(test_helper.mailbox_length(limiter) <= 3)
  occupancy(sockets).items |> should.equal(4)
  test_helper.resume_process(limiter)
  wait_empty(sockets)
  let assert Ok(next) = transport.acquire_connection_slot(sockets, "192.0.2.1")
  transport.release_connection_slot(next)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn bind_and_release_tolerate_unavailable_limiter_test() -> Nil {
  let sockets = start(4, 4096)
  let assert Ok(first) = transport.acquire_connection_slot(sockets, "192.0.2.1")
  let assert Ok(second) =
    transport.acquire_connection_slot(sockets, "192.0.2.2")
  beryl.stop(sockets) |> should.equal(Ok(Nil))
  transport.bind_connection_slot(first) |> should.equal(Error(Nil))
  transport.release_connection_slot(first)
  transport.release_connection_slot(second)
}

pub fn replacement_discards_pending_work_but_preserves_holders_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(4, 4096)
  let assert Ok(first) = transport.acquire_connection_slot(sockets, "192.0.2.1")
  wait_empty(sockets)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)
  abandon_request(sockets, 2)
  abandon_request(sockets, 4)
  process.kill(limiter)
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets) {
        Ok(replacement) -> replacement != limiter
        Error(Nil) -> False
      }
    },
    1000,
    1,
  )
  occupancy(sockets).items |> should.equal(0)
  transport.acquire_connection_slot(sockets, "192.0.2.1")
  |> should.equal(Error(Nil))
  let assert Ok(second) =
    transport.acquire_connection_slot(sockets, "192.0.2.2")
  transport.acquire_connection_slot(sockets, "192.0.2.3")
  |> should.equal(Error(Nil))
  transport.release_connection_slot(first)
  let assert Ok(third) = transport.acquire_connection_slot(sockets, "192.0.2.1")
  transport.release_connection_slot(second)
  transport.release_connection_slot(third)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn oversized_peer_ip_is_rejected_before_publication_test() -> Nil {
  let sockets = start(4, 1024)
  transport.acquire_connection_slot(sockets, string.repeat("x", 1025))
  |> should.equal(Error(Nil))
  let snapshot = occupancy(sockets)
  snapshot.items |> should.equal(0)
  snapshot.high_items |> should.equal(0)
  snapshot.rejected |> should.equal(1)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  transport.release_connection_slot(permit)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}

pub fn replacement_rejects_unacknowledged_reply_from_old_limiter_test() -> Nil {
  use <- unitest.tag("serial")
  let sockets = start(4, 4096)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  test_helper.suspend_process(limiter)
  let result = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(
        result,
        transport.acquire_connection_slot(sockets, "192.0.2.1"),
      )
    })
  test_helper.wait_until(fn() { occupancy(sockets).items == 2 }, 500, 1)
  test_helper.suspend_process(caller)
  test_helper.resume_process(limiter)
  test_helper.wait_until(fn() { occupancy(sockets).items == 1 }, 500, 1)
  process.kill(limiter)
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(sockets) {
        Ok(replacement) -> replacement != limiter
        Error(Nil) -> False
      }
    },
    1000,
    1,
  )
  // Acquiring from the replacement is also a barrier for checkpoint recovery.
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.1")
  test_helper.resume_process(caller)
  process.receive(result, 500) |> should.equal(Ok(Error(Nil)))
  transport.release_connection_slot(permit)
  wait_empty(sockets)
  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
