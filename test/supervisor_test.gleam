import beryl
import beryl/channel
import beryl/group
import beryl/presence
import beryl/supervisor
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleeunit/should

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
  let assert Ok(pid) = get_subject_pid(coord_subject)
  process.send_abnormal_exit(pid, crash_reason())

  // Wait for the supervisor to restart the coordinator
  process.sleep(100)

  // After restart, the coordinator should accept new registrations.
  // Note: previous registrations are lost (fresh state), which is expected.
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result = beryl.register(supervised.channels, "post-crash:*", handler2)
  result |> should.be_ok
}

// FFI helpers for test

@external(erlang, "beryl_supervisor_test_ffi", "get_subject_pid")
fn get_subject_pid(subject: process.Subject(a)) -> Result(process.Pid, Nil)

@external(erlang, "beryl_supervisor_test_ffi", "crash_reason")
fn crash_reason() -> a
