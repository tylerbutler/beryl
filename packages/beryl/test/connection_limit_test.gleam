//// Per-IP connection limit enforcement tests.
////
//// These exercise the public transport-facing API
//// (`transport.acquire_connection_slot` / `transport.release_connection_slot`)
//// which transports use to admit or reject WebSocket upgrades based on the
//// real socket peer IP.

import app_test_helper
import beryl
import beryl/connection_limit
import beryl/overload
import beryl/socket
import beryl/transport
import beryl/wire
import beryl_heirloom as heirloom
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/list
import gleam/option
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/otp/supervision
import gleeunit/should
import test_helper
import unitest

type CheckpointValue

type CheckpointTable =
  heirloom.Table(String, CheckpointValue)

@external(erlang, "beryl_supervisor_test_ffi", "connection_limit_checkpoint_table")
fn checkpoint_table(limiter: process.Pid) -> Result(CheckpointTable, Nil)

@external(erlang, "beryl_supervisor_test_ffi", "checkpoint_manager_sync")
fn checkpoint_manager_sync(manager: process.Pid) -> Nil

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

fn kill_fixture(pid: process.Pid) -> Nil {
  let monitor = process.monitor(pid)
  process.unlink(pid)
  process.kill(pid)
  process.new_selector()
  |> process.select_specific_monitor(monitor, fn(_) { Nil })
  |> process.selector_receive(2000)
  |> should.equal(Ok(Nil))
}

fn with_checkpoint_manager(
  action: fn(process.Subject(connection_limit.CheckpointMessage), process.Pid) ->
    Nil,
) -> Nil {
  let name = process.new_name("checkpoint_manager_fixture")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(
      supervision.worker(fn() {
        connection_limit.start_checkpoint_manager(name)
      }),
    )
    |> static_supervisor.start()
  let manager = process.named_subject(name)
  let assert Ok(owner) = process.subject_owner(manager)
  action(manager, owner)
  kill_fixture(supervisor.pid)
  test_helper.wait_until(fn() { !process.is_alive(owner) }, 2000, 1)
}

fn receive_checkpoint(manager: process.Pid) -> #(CheckpointTable, Bool) {
  let assert Ok(Ok(heirloom.Transfer(table, previous_owner, established))) =
    process.new_selector()
    |> heirloom.select_transfers(decode.bool, fn(transfer) { transfer })
    |> process.selector_receive(1000)
  previous_owner |> should.equal(manager)
  heirloom.owner(table) |> should.equal(Ok(process.self()))
  #(table, established)
}

fn empty_checkpoint_holder(
  manager: process.Subject(connection_limit.CheckpointMessage),
  owner: process.Pid,
  established: Bool,
) -> #(process.Pid, CheckpointTable) {
  let ready = process.new_subject()
  let holder =
    process.spawn(fn() {
      connection_limit.claim_checkpoint(manager, process.self())
      let #(table, fresh) = receive_checkpoint(owner)
      fresh |> should.be_false
      let assert Ok(Nil) = heirloom.set_heir(table, owner, established)
      process.send(ready, table)
      process.sleep_forever()
    })
  let assert Ok(table) = process.receive(ready, 1000)
  #(holder, table)
}

pub fn checkpoint_claim_before_transfer_receives_table_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let #(holder, original) = empty_checkpoint_holder(manager, owner, False)
  connection_limit.claim_checkpoint(manager, process.self())
  checkpoint_manager_sync(owner)
  heirloom.owner(original) |> should.equal(Ok(holder))
  kill_fixture(holder)
  let #(table, established) = receive_checkpoint(owner)
  table |> should.equal(original)
  established |> should.be_false
  let assert Ok(Nil) = heirloom.give_away(table, owner, False)
  checkpoint_manager_sync(owner)
}

pub fn dead_pending_checkpoint_claim_does_not_strand_table_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let #(holder, original) = empty_checkpoint_holder(manager, owner, False)
  let claimant = process.spawn(fn() { process.sleep_forever() })
  connection_limit.claim_checkpoint(manager, claimant)
  checkpoint_manager_sync(owner)
  kill_fixture(claimant)
  connection_limit.claim_checkpoint(manager, process.self())
  checkpoint_manager_sync(owner)
  kill_fixture(holder)
  let #(table, _) = receive_checkpoint(owner)
  table |> should.equal(original)
  let assert Ok(Nil) = heirloom.give_away(table, owner, False)
  checkpoint_manager_sync(owner)
}

pub fn dead_checkpoint_recipient_leaves_table_available_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let assert Ok(original) = checkpoint_table(owner)
  let claimant = process.spawn(fn() { process.sleep_forever() })
  kill_fixture(claimant)
  connection_limit.claim_checkpoint(manager, claimant)
  checkpoint_manager_sync(owner)
  heirloom.owner(original) |> should.equal(Ok(owner))
  connection_limit.claim_checkpoint(manager, process.self())
  let #(table, _) = receive_checkpoint(owner)
  table |> should.equal(original)
  let assert Ok(Nil) = heirloom.give_away(table, owner, False)
  checkpoint_manager_sync(owner)
}

pub fn fresh_checkpoint_survives_exit_before_initial_write_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let #(holder, original) = empty_checkpoint_holder(manager, owner, False)
  kill_fixture(holder)
  let name = process.new_name("fresh_checkpoint_limiter")
  let assert Ok(started) =
    connection_limit.start_named(
      1,
      1,
      1,
      1,
      overload.shared_limits(),
      name,
      manager,
    )
  checkpoint_table(started.pid) |> should.equal(Ok(original))
  let limiter = connection_limit.from_name(name)
  let assert Ok(permit) =
    connection_limit.acquire_optional(option.Some(limiter), "192.0.2.1")
  connection_limit.release_optional(permit)
  kill_fixture(started.pid)
  checkpoint_manager_sync(owner)
}

pub fn missing_established_checkpoint_state_rejects_initialization_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let #(holder, original) = empty_checkpoint_holder(manager, owner, True)
  kill_fixture(holder)
  let name = process.new_name("missing_checkpoint_limiter")
  connection_limit.start_named(
    1,
    1,
    1,
    1,
    overload.shared_limits(),
    name,
    manager,
  )
  |> should.equal(
    Error(actor.InitFailed("Connection limiter checkpoint state is missing")),
  )
  test_helper.wait_until(
    fn() { heirloom.owner(original) == Ok(owner) },
    1000,
    1,
  )
  heirloom.exists(original) |> should.be_true
  connection_limit.acquire_optional(
    option.Some(connection_limit.from_name(name)),
    "192.0.2.1",
  )
  |> should.equal(Error(Nil))
}

pub fn checkpoint_transfer_timeout_does_not_create_fallback_table_test() -> Nil {
  use <- unitest.tag("serial")
  use <- test_helper.with_isolated_caller(5000)
  use manager, owner <- with_checkpoint_manager
  let #(holder, original) = empty_checkpoint_holder(manager, owner, False)
  let name = process.new_name("checkpoint_timeout_limiter")
  connection_limit.start_named(
    1,
    1,
    1,
    1,
    overload.shared_limits(),
    name,
    manager,
  )
  |> should.equal(
    Error(actor.InitFailed("Connection limiter checkpoint transfer timed out")),
  )
  heirloom.owner(original) |> should.equal(Ok(holder))
  test_helper.wait_until(
    fn() {
      connection_limit.pid(connection_limit.from_name(name)) == Error(Nil)
    },
    1000,
    1,
  )
  kill_fixture(holder)
  let assert Ok(started) =
    connection_limit.start_named(
      1,
      1,
      1,
      1,
      overload.shared_limits(),
      name,
      manager,
    )
  checkpoint_table(started.pid) |> should.equal(Ok(original))
  kill_fixture(started.pid)
  checkpoint_manager_sync(owner)
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

// A timed-out request suppresses its late reply and activates reserved cleanup,
// so no mailbox message or reservation remains.
pub fn timed_out_queued_acquire_is_cancelled_test() -> Nil {
  let channels = start_with_limit(1)
  let assert Ok(limiter) = beryl.app_limiter_pid(channels)
  test_helper.suspend_process(limiter)

  let outcome = process.new_subject()
  let finished = process.new_subject()
  let _pid =
    process.spawn_unlinked(fn() {
      let continue = process.new_subject()
      process.send(outcome, #(
        transport.acquire_connection_slot(channels, "10.0.0.8"),
        continue,
      ))
      let assert Ok(Nil) = process.receive(continue, 2000)
      let barrier = case
        transport.acquire_connection_slot(channels, "10.0.0.8")
      {
        Ok(permit) -> {
          transport.release_connection_slot(permit)
          True
        }
        Error(Nil) -> False
      }
      process.send(finished, #(
        barrier,
        test_helper.mailbox_length(process.self()),
      ))
    })
  let assert Ok(#(Error(Nil), continue)) = process.receive(outcome, 500)

  test_helper.resume_process(limiter)
  process.send(continue, Nil)
  process.receive(finished, 1000) |> should.equal(Ok(#(True, 0)))

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn timed_out_bind_suppresses_late_reply_test() -> Nil {
  let channels = start_with_limit(1)
  let assert Ok(permit) =
    transport.acquire_connection_slot(channels, "10.0.0.14")
  let assert Ok(limiter) = beryl.app_limiter_pid(channels)
  test_helper.suspend_process(limiter)

  let outcome = process.new_subject()
  let finished = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let continue = process.new_subject()
      process.send(outcome, #(transport.bind_connection_slot(permit), continue))
      let assert Ok(Nil) = process.receive(continue, 2000)
      let barrier = case
        transport.acquire_connection_slot(channels, "10.0.0.15")
      {
        Ok(next) -> {
          transport.release_connection_slot(next)
          True
        }
        Error(Nil) -> False
      }
      process.send(finished, #(
        barrier,
        test_helper.mailbox_length(process.self()),
      ))
    })
  let assert Ok(#(Error(Nil), continue)) = process.receive(outcome, 500)

  test_helper.resume_process(limiter)
  process.send(continue, Nil)
  process.receive(finished, 1000) |> should.equal(Ok(#(True, 0)))
  test_helper.wait_until(
    fn() {
      case transport.acquire_connection_slot(channels, "10.0.0.14") {
        Ok(next) -> {
          transport.release_connection_slot(next)
          True
        }
        Error(Nil) -> False
      }
    },
    1000,
    10,
  )

  let assert Ok(Nil) = beryl.stop(channels)
  Nil
}

pub fn acquire_returns_error_when_limiter_dies_while_waiting_test() -> Nil {
  use <- unitest.tag("serial")
  let channels = start_with_limit(1)
  let assert Ok(limiter) = beryl.app_limiter_pid(channels)
  test_helper.suspend_process(limiter)

  let outcome = process.new_subject()
  let _caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, #(
        transport.acquire_connection_slot(channels, "10.0.0.16"),
        test_helper.mailbox_length(process.self()),
      ))
    })
  let assert option.Some(registry) =
    beryl.configured_connection_limiter(channels)
  test_helper.wait_until(
    fn() {
      let assert Ok(snapshot) = connection_limit.queue_snapshot(registry)
      snapshot.items == 2
    },
    500,
    10,
  )
  process.kill(limiter)

  process.receive(outcome, 500) |> should.equal(Ok(#(Error(Nil), 0)))
  test_helper.wait_until(
    fn() {
      case beryl.app_limiter_pid(channels) {
        Ok(replacement) -> replacement != limiter
        Error(Nil) -> False
      }
    },
    1000,
    10,
  )
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

pub fn cancelled_slot_is_reusable_before_release_notification_test() -> Nil {
  list.each([True, False], fn(per_ip) {
    let config = case per_ip {
      True ->
        beryl.config(wire.phoenix_codec())
        |> beryl.with_max_connections_per_ip(1)
      False ->
        beryl.config(wire.phoenix_codec()) |> beryl.with_max_connections(1)
    }
    let assert Ok(channels) =
      app_test_helper.start_app(
        config,
        init: fn(_) { #(Nil, []) },
        update: fn(model: Nil, _: socket.Input(Nil)) { socket.Next(model, []) },
      )
    let assert Ok(option.Some(permit)) =
      connection_limit.acquire_optional(
        beryl.configured_connection_limiter(channels),
        "192.0.2.1",
      )
    let assert option.Some(limiter) =
      beryl.configured_connection_limiter(channels)
    test_helper.wait_until(
      fn() {
        let assert Ok(queue) = connection_limit.queue_snapshot(limiter)
        queue.items == 0
      },
      1000,
      1,
    )
    connection_limit.release_with_cancel_hook(permit, fn() {
      let ip = case per_ip {
        True -> "192.0.2.1"
        False -> "192.0.2.2"
      }
      let assert Ok(next) = transport.acquire_connection_slot(channels, ip)
      transport.release_connection_slot(next)
    })
    beryl.stop(channels) |> should.equal(Ok(Nil))
  })
}

pub fn transferred_slot_survives_requester_exit_and_restart_test() -> Nil {
  use <- unitest.tag("serial")
  let channels = start_with_limit(1)
  let acquired = process.new_subject()
  let requester =
    process.spawn_unlinked(fn() {
      let exit = process.new_subject()
      let assert Ok(permit) =
        transport.acquire_connection_slot(channels, "10.0.0.13")
      process.send(acquired, #(permit, exit))
      let assert Ok(Nil) = process.receive(exit, 2000)
    })
  let assert Ok(#(permit, exit)) = process.receive(acquired, 500)
  transport.bind_connection_slot(permit) |> should.equal(Ok(Nil))
  process.send(exit, Nil)
  test_helper.wait_until(fn() { !process.is_alive(requester) }, 1000, 10)

  transport.bind_connection_slot(permit) |> should.equal(Ok(Nil))
  let assert Ok(old_limiter) = beryl.app_limiter_pid(channels)
  process.kill(old_limiter)
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
  transport.acquire_connection_slot(channels, "10.0.0.13")
  |> should.be_error
  transport.bind_connection_slot(permit) |> should.equal(Ok(Nil))
  transport.release_connection_slot(permit)
  let assert Ok(next) = transport.acquire_connection_slot(channels, "10.0.0.13")
  transport.release_connection_slot(next)
  beryl.stop(channels) |> should.equal(Ok(Nil))
}

pub fn cancellation_survives_limiter_restart_test() -> Nil {
  use <- unitest.tag("serial")
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
