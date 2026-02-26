import beryl
import beryl/channel
import beryl/group
import beryl/presence
import beryl/supervisor
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should
import test_helpers

// ── Supervised startup tests ────────────────────────────────────────────────

pub fn start_supervised_coordinator_only_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: False,
    )

  let result = supervisor.start(config)
  result |> should.be_ok

  let assert Ok(supervised) = result
  supervised.presence |> should.be_none
  supervised.groups |> should.be_none
}

pub fn start_supervised_all_subsystems_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-node")),
      groups: True,
    )

  let result = supervisor.start(config)
  result |> should.be_ok

  let assert Ok(supervised) = result
  supervised.presence |> should.be_some
  supervised.groups |> should.be_some
}

pub fn start_supervised_with_presence_only_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-node-2")),
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)
  supervised.presence |> should.be_some
  supervised.groups |> should.be_none
}

pub fn start_supervised_with_groups_only_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: True,
    )

  let assert Ok(supervised) = supervisor.start(config)
  supervised.presence |> should.be_none
  supervised.groups |> should.be_some
}

// ── Subsystem accessibility tests ───────────────────────────────────────────

pub fn supervised_coordinator_accepts_register_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)

  // Register a channel handler to verify the coordinator is functional
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })

  let result = beryl.register(supervised.channels, "test:*", handler)
  result |> should.be_ok
}

pub fn supervised_presence_tracks_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-track")),
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(pres) = supervised.presence

  // Track a presence and verify it's queryable
  let _ref =
    presence.track(pres, "room:lobby", "user:1", "pid1", json.object([]))

  let entries = presence.list(pres, "room:lobby")
  entries |> should.not_equal([])
}

pub fn supervised_groups_work_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: True,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(grps) = supervised.groups

  // Create a group and verify it's queryable
  let assert Ok(Nil) = group.create(grps, "team:eng")
  let names = group.list_groups(grps)
  names |> should.equal(["team:eng"])
}

// ── Stop / lifecycle tests ─────────────────────────────────────────────────

pub fn stop_shuts_down_supervisor_and_children_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-stop")),
      groups: True,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(pres) = supervised.presence
  let assert Some(grps) = supervised.groups

  // Verify everything is running
  let _ref =
    presence.track(pres, "room:stop", "user:1", "pid1", json.object([]))
  let assert Ok(Nil) = group.create(grps, "team:stop")

  // Get PIDs before stopping
  let sup_pid = supervised.supervisor_pid
  let assert Ok(coord_pid) = get_subject_pid(supervised.channels.coordinator)

  // Stop the supervisor
  supervisor.stop(supervised)

  // Supervisor process should be dead
  process.is_alive(sup_pid) |> should.be_false

  // Coordinator should also be dead (was a child)
  process.is_alive(coord_pid) |> should.be_false
}

pub fn stop_coordinator_only_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)

  // Verify coordinator is running
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(Nil) =
    beryl.register(supervised.channels, "pre-stop:*", handler)

  let sup_pid = supervised.supervisor_pid
  supervisor.stop(supervised)

  process.is_alive(sup_pid) |> should.be_false
}

// ── Restart behavior test ───────────────────────────────────────────────────

pub fn supervised_coordinator_restarts_on_crash_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)

  // Get the coordinator subject and verify it works
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(Nil) =
    beryl.register(supervised.channels, "pre-crash:*", handler)

  // Kill the coordinator process
  let assert Ok(name) = process.subject_name(supervised.channels.coordinator)
  let coord_subject = process.named_subject(name)

  // Send an exit signal to crash the coordinator
  let assert Ok(old_pid) = get_subject_pid(coord_subject)
  process.send_abnormal_exit(old_pid, crash_reason())

  // Poll until a new coordinator process is alive with a different PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(coord_subject) {
        Ok(new_pid) -> new_pid != old_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // After restart, verify the new coordinator accepts registrations
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result = beryl.register(supervised.channels, "post-crash:*", handler2)
  result |> should.be_ok
}

// ── RestForOne cascading restart tests ─────────────────────────────────────
// These tests prove RestForOne strategy is actually needed. They would fail
// with OneForOne because downstream children (presence, groups) would NOT
// be restarted when the coordinator crashes.

pub fn coordinator_crash_resets_presence_state_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-rest-for-one-pres")),
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(pres) = supervised.presence

  // Track a presence entry and verify it exists
  let _ref =
    presence.track(pres, "room:cascade", "user:1", "pid1", json.object([]))
  presence.list(pres, "room:cascade") |> should.not_equal([])

  // Get coordinator PID and kill it
  let assert Ok(name) = process.subject_name(supervised.channels.coordinator)
  let coord_subject = process.named_subject(name)
  let assert Ok(old_coord_pid) = get_subject_pid(coord_subject)

  // Also get the presence PID before crash
  let assert Ok(old_pres_pid) = get_subject_pid(pres.subject)

  process.send_abnormal_exit(old_coord_pid, crash_reason())

  // Wait for coordinator to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(coord_subject) {
        Ok(new_pid) -> new_pid != old_coord_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Wait for presence to also restart with a new PID (RestForOne behavior)
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(pres.subject) {
        Ok(new_pid) -> new_pid != old_pres_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Presence state should be empty after restart (fresh state)
  // This is the key assertion: with OneForOne, presence would NOT restart
  // and would still have the old entry.
  presence.list(pres, "room:cascade") |> should.equal([])
}

pub fn coordinator_crash_resets_groups_state_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: True,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(grps) = supervised.groups

  // Create a group and verify it exists
  let assert Ok(Nil) = group.create(grps, "team:cascade")
  group.list_groups(grps) |> should.equal(["team:cascade"])

  // Get coordinator PID and kill it
  let assert Ok(name) = process.subject_name(supervised.channels.coordinator)
  let coord_subject = process.named_subject(name)
  let assert Ok(old_coord_pid) = get_subject_pid(coord_subject)

  // Also get the groups PID before crash
  let assert Ok(old_grps_pid) = get_subject_pid(grps.subject)

  process.send_abnormal_exit(old_coord_pid, crash_reason())

  // Wait for coordinator to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(coord_subject) {
        Ok(new_pid) -> new_pid != old_coord_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Wait for groups to also restart with a new PID (RestForOne behavior)
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(grps.subject) {
        Ok(new_pid) -> new_pid != old_grps_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Groups state should be empty after restart (fresh state)
  // This would fail with OneForOne: groups would retain stale state.
  group.list_groups(grps) |> should.equal([])
}

pub fn independent_presence_crash_does_not_affect_coordinator_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: Some(presence.default_config("test-indep-pres")),
      groups: False,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(pres) = supervised.presence

  // Register a channel handler on the coordinator
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(Nil) =
    beryl.register(supervised.channels, "indep-pres:*", handler)

  // Get coordinator PID before
  let assert Ok(coord_pid_before) =
    get_subject_pid(supervised.channels.coordinator)

  // Kill the presence process directly
  let assert Ok(old_pres_pid) = get_subject_pid(pres.subject)
  process.send_abnormal_exit(old_pres_pid, crash_reason())

  // Wait for presence to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(pres.subject) {
        Ok(new_pid) -> new_pid != old_pres_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Coordinator should still be the same process (not restarted)
  let assert Ok(coord_pid_after) =
    get_subject_pid(supervised.channels.coordinator)
  coord_pid_after |> should.equal(coord_pid_before)

  // Coordinator should still be functional with its existing state
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result =
    beryl.register(supervised.channels, "indep-pres-after:*", handler2)
  result |> should.be_ok
}

pub fn independent_groups_crash_does_not_affect_coordinator_test() {
  let config =
    supervisor.SupervisedConfig(
      channels: beryl.default_config(),
      presence: None,
      groups: True,
    )

  let assert Ok(supervised) = supervisor.start(config)
  let assert Some(grps) = supervised.groups

  // Register a channel handler on the coordinator
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(Nil) =
    beryl.register(supervised.channels, "indep-grps:*", handler)

  // Get coordinator PID before
  let assert Ok(coord_pid_before) =
    get_subject_pid(supervised.channels.coordinator)

  // Kill the groups process directly
  let assert Ok(old_grps_pid) = get_subject_pid(grps.subject)
  process.send_abnormal_exit(old_grps_pid, crash_reason())

  // Wait for groups to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(grps.subject) {
        Ok(new_pid) -> new_pid != old_grps_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Coordinator should still be the same process (not restarted)
  let assert Ok(coord_pid_after) =
    get_subject_pid(supervised.channels.coordinator)
  coord_pid_after |> should.equal(coord_pid_before)

  // Coordinator should still be functional
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result =
    beryl.register(supervised.channels, "indep-grps-after:*", handler2)
  result |> should.be_ok
}

// FFI helpers for test

@external(erlang, "beryl_supervisor_test_ffi", "get_subject_pid")
fn get_subject_pid(subject: process.Subject(a)) -> Result(process.Pid, Nil)

@external(erlang, "beryl_supervisor_test_ffi", "crash_reason")
fn crash_reason() -> a
