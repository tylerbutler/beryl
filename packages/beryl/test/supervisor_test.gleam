import beryl
import beryl/channel
import beryl/coordinator
import beryl/group
import beryl/presence
import beryl/stats
import beryl/supervisor
import beryl/wire
import gleam/dynamic
import gleam/erlang/process
import gleam/json
import gleam/option.{None, Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/string
import gleeunit/should
import test_helpers

// ── Supervised startup tests ────────────────────────────────────────────────

pub fn start_supervised_coordinator_only_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))

  let result = start_supervised(config)
  result |> should.be_ok

  let assert Ok(#(supervised, _root)) = result
  supervisor.presence(supervised) |> should.be_none
  supervisor.groups(supervised) |> should.be_none
}

pub fn start_supervised_all_subsystems_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("test-node"))
    |> supervisor.with_groups()

  let result = start_supervised(config)
  result |> should.be_ok

  let assert Ok(#(supervised, _root)) = result
  supervisor.presence(supervised) |> should.be_some
  supervisor.groups(supervised) |> should.be_some
}

pub fn start_supervised_with_presence_only_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("test-node-2"))

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  supervisor.presence(supervised) |> should.be_some
  supervisor.groups(supervised) |> should.be_none
}

pub fn start_supervised_with_groups_only_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_groups()

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  supervisor.presence(supervised) |> should.be_none
  supervisor.groups(supervised) |> should.be_some
}

// ── Subsystem accessibility tests ───────────────────────────────────────────

pub fn supervised_coordinator_accepts_register_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))

  let assert Ok(#(supervised, _root)) = start_supervised(config)

  // Register a channel handler to verify the coordinator is functional
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })

  let result =
    beryl.register(supervisor.channels(supervised), "test:*", handler)
  result |> should.be_ok
}

pub fn supervised_presence_tracks_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("test-track"))

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(pres) = supervisor.presence(supervised)

  // Track a presence and verify it's queryable
  let _ref =
    presence.track(pres, "room:lobby", "user:1", "pid1", json.object([]))

  let entries = presence.list(pres, "room:lobby")
  entries |> should.not_equal([])
}

pub fn supervised_groups_work_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_groups()

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(grps) = supervisor.groups(supervised)

  // Create a group and verify it's queryable
  let assert Ok(Nil) = group.create(grps, "team:eng")
  let names = group.list_groups(grps)
  names |> should.equal(["team:eng"])
}

pub fn connection_limiter_is_owned_by_supervision_tree_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections(1)
    |> supervisor.config()

  let assert Ok(#(supervised, root)) = start_supervised(config)
  let channels = supervisor.channels(supervised)
  let assert Ok(_permit) = beryl.acquire_connection_slot(channels, "127.0.0.1")

  stop_supervisor(root.pid)

  beryl.acquire_connection_slot(channels, "127.0.0.2")
  |> should.be_error
}

// ── Stop / lifecycle tests ─────────────────────────────────────────────────

pub fn stop_shuts_down_supervisor_and_children_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("test-stop"))
    |> supervisor.with_groups()

  let assert Ok(#(supervised, root)) = start_supervised(config)
  let assert Some(pres) = supervisor.presence(supervised)
  let assert Some(grps) = supervisor.groups(supervised)

  // Verify everything is running
  let _ref =
    presence.track(pres, "room:stop", "user:1", "pid1", json.object([]))
  let assert Ok(Nil) = group.create(grps, "team:stop")

  // Get PIDs before stopping
  let sup_pid = root.pid
  let assert Ok(coord_pid) =
    get_subject_pid(beryl.coordinator_subject(supervisor.channels(supervised)))

  // Stop the supervisor
  stop_supervisor(root.pid)

  // Supervisor process should be dead
  process.is_alive(sup_pid) |> should.be_false

  // Coordinator should also be dead (was a child)
  process.is_alive(coord_pid) |> should.be_false
}

pub fn stop_coordinator_only_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))

  let assert Ok(#(supervised, root)) = start_supervised(config)

  // Verify coordinator is running
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) =
    beryl.register(supervisor.channels(supervised), "pre-stop:*", handler)

  let sup_pid = root.pid
  stop_supervisor(root.pid)

  process.is_alive(sup_pid) |> should.be_false
}

// ── Restart behavior test ───────────────────────────────────────────────────

pub fn supervised_coordinator_restarts_on_crash_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))

  let assert Ok(#(supervised, _root)) = start_supervised(config)

  // Get the coordinator subject and verify it works
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) =
    beryl.register(supervisor.channels(supervised), "pre-crash:*", handler)

  // Kill the coordinator process
  let assert Ok(name) =
    process.subject_name(
      beryl.coordinator_subject(supervisor.channels(supervised)),
    )
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
  let result =
    beryl.register(supervisor.channels(supervised), "post-crash:*", handler2)
  result |> should.be_ok
}

pub fn registrations_survive_coordinator_restart_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))
  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let channels = supervisor.channels(supervised)

  // Register before the crash — and never again afterwards.
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "survivor:*", handler)

  // Crash the coordinator and wait for the supervisor to restart it.
  let assert Ok(name) =
    process.subject_name(beryl.coordinator_subject(channels))
  let coord_subject = process.named_subject(name)
  let assert Ok(old_pid) = get_subject_pid(coord_subject)
  process.send_abnormal_exit(old_pid, crash_reason())
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

  // A join on the pre-crash pattern succeeds without re-registering: the
  // restarted coordinator re-seeded its handlers from the registry.
  let sent = process.new_subject()
  process.send(
    coord_subject,
    coordinator.SocketConnected(
      "post-restart-socket",
      fn(text) {
        process.send(sent, text)
        Ok(Nil)
      },
      fn(_) { Ok(Nil) },
      None,
      dynamic.nil(),
    ),
  )
  process.sleep(10)
  coordinator.route_message(
    coord_subject,
    "post-restart-socket",
    "[\"j1\",\"j1\",\"survivor:lobby\",\"phx_join\",{}]",
  )

  let assert Ok(reply) = process.receive(sent, 1000)
  reply |> string.contains("phx_reply") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn stats_survive_coordinator_restart_test() {
  let config = supervisor.config(beryl.config(wire.phoenix_codec()))
  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let channels = supervisor.channels(supervised)
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) = beryl.register(channels, "stats-survivor:*", handler)

  let coordinator_subject = beryl.coordinator_subject(channels)
  let assert Ok(old_pid) = get_subject_pid(coordinator_subject)
  let race_results = process.new_subject()
  spawn_stats_requests(channels, race_results, 20)
  process.send_abnormal_exit(old_pid, crash_reason())

  // Concurrent requests make the unregister-between-check-and-send race
  // feasible. Every worker must return a typed result rather than crashing.
  receive_stats_results(race_results, 20)

  test_helpers.wait_until(
    fn() {
      case get_subject_pid(coordinator_subject) {
        Ok(new_pid) -> new_pid != old_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  let assert Ok(snapshot) = stats.snapshot(channels)
  stats.registered_channel_handlers(snapshot) |> should.equal(1)
  stats.connected_sockets(snapshot) |> should.equal(0)
}

fn spawn_stats_requests(
  channels: beryl.Channels,
  results: process.Subject(Result(stats.Snapshot, stats.SnapshotError)),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let _worker =
        process.spawn_unlinked(fn() {
          process.send(results, stats.snapshot(channels))
        })
      spawn_stats_requests(channels, results, remaining - 1)
    }
  }
}

fn receive_stats_results(
  results: process.Subject(Result(stats.Snapshot, stats.SnapshotError)),
  remaining: Int,
) -> Nil {
  case remaining <= 0 {
    True -> Nil
    False -> {
      let assert Ok(result) = process.receive(results, 2000)
      let Nil = case result {
        Ok(_)
        | Error(stats.CoordinatorUnavailable)
        | Error(stats.RequestTimedOut) -> Nil
      }
      receive_stats_results(results, remaining - 1)
    }
  }
}

// ── RestForOne cascading restart tests ─────────────────────────────────────
// These tests prove RestForOne strategy is actually needed. They would fail
// with OneForOne because downstream children (presence, groups) would NOT
// be restarted when the coordinator crashes.

pub fn coordinator_crash_resets_presence_state_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config(
      "test-rest-for-one-pres",
    ))

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(pres) = supervisor.presence(supervised)

  // Track a presence entry and verify it exists
  let _ref =
    presence.track(pres, "room:cascade", "user:1", "pid1", json.object([]))
  presence.list(pres, "room:cascade") |> should.not_equal([])

  // Get coordinator PID and kill it
  let assert Ok(name) =
    process.subject_name(
      beryl.coordinator_subject(supervisor.channels(supervised)),
    )
  let coord_subject = process.named_subject(name)
  let assert Ok(old_coord_pid) = get_subject_pid(coord_subject)

  // Also get the presence PID before crash
  let assert Ok(old_pres_pid) = get_subject_pid(presence.subject(pres))

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
      case get_subject_pid(presence.subject(pres)) {
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
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_groups()

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(grps) = supervisor.groups(supervised)

  // Create a group and verify it exists
  let assert Ok(Nil) = group.create(grps, "team:cascade")
  group.list_groups(grps) |> should.equal(["team:cascade"])

  // Get coordinator PID and kill it
  let assert Ok(name) =
    process.subject_name(
      beryl.coordinator_subject(supervisor.channels(supervised)),
    )
  let coord_subject = process.named_subject(name)
  let assert Ok(old_coord_pid) = get_subject_pid(coord_subject)

  // Also get the groups PID before crash
  let assert Ok(old_grps_pid) = get_subject_pid(group.subject(grps))

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
      case get_subject_pid(group.subject(grps)) {
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
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_presence(presence.default_config("test-indep-pres"))

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(pres) = supervisor.presence(supervised)

  // Register a channel handler on the coordinator
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) =
    beryl.register(supervisor.channels(supervised), "indep-pres:*", handler)

  // Get coordinator PID before
  let assert Ok(coord_pid_before) =
    get_subject_pid(beryl.coordinator_subject(supervisor.channels(supervised)))

  // Kill the presence process directly
  let assert Ok(old_pres_pid) = get_subject_pid(presence.subject(pres))
  process.send_abnormal_exit(old_pres_pid, crash_reason())

  // Wait for presence to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(presence.subject(pres)) {
        Ok(new_pid) -> new_pid != old_pres_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Coordinator should still be the same process (not restarted)
  let assert Ok(coord_pid_after) =
    get_subject_pid(beryl.coordinator_subject(supervisor.channels(supervised)))
  coord_pid_after |> should.equal(coord_pid_before)

  // Coordinator should still be functional with its existing state
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result =
    beryl.register(
      supervisor.channels(supervised),
      "indep-pres-after:*",
      handler2,
    )
  result |> should.be_ok
}

pub fn independent_groups_crash_does_not_affect_coordinator_test() {
  let config =
    supervisor.config(beryl.config(wire.phoenix_codec()))
    |> supervisor.with_groups()

  let assert Ok(#(supervised, _root)) = start_supervised(config)
  let assert Some(grps) = supervisor.groups(supervised)

  // Register a channel handler on the coordinator
  let handler =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let assert Ok(_) =
    beryl.register(supervisor.channels(supervised), "indep-grps:*", handler)

  // Get coordinator PID before
  let assert Ok(coord_pid_before) =
    get_subject_pid(beryl.coordinator_subject(supervisor.channels(supervised)))

  // Kill the groups process directly
  let assert Ok(old_grps_pid) = get_subject_pid(group.subject(grps))
  process.send_abnormal_exit(old_grps_pid, crash_reason())

  // Wait for groups to restart with a new PID
  test_helpers.wait_until(
    fn() {
      case get_subject_pid(group.subject(grps)) {
        Ok(new_pid) -> new_pid != old_grps_pid && process.is_alive(new_pid)
        Error(_) -> False
      }
    },
    2000,
    10,
  )

  // Coordinator should still be the same process (not restarted)
  let assert Ok(coord_pid_after) =
    get_subject_pid(beryl.coordinator_subject(supervisor.channels(supervised)))
  coord_pid_after |> should.equal(coord_pid_before)

  // Coordinator should still be functional
  let handler2 =
    channel.new(fn(_topic, _payload, socket) {
      channel.JoinOk(reply: None, socket: socket)
    })
  let result =
    beryl.register(
      supervisor.channels(supervised),
      "indep-grps-after:*",
      handler2,
    )
  result |> should.be_ok
}

// FFI helpers for test

fn start_supervised(config: supervisor.SupervisedConfig) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(supervisor.start(config))
  |> static_supervisor.start()
  |> result.map(fn(root) { #(config, root) })
}

@external(erlang, "beryl_supervisor_test_ffi", "get_subject_pid")
fn get_subject_pid(subject: process.Subject(a)) -> Result(process.Pid, Nil)

@external(erlang, "beryl_supervisor_test_ffi", "crash_reason")
fn crash_reason() -> a

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil
