//// Exact-router ownership through the transport SPI. Gates are created by
//// the callback, and only their unique subject can release the callback.

import app_test_helper
import beryl
import beryl/channel
import beryl/presence
import beryl/socket
import beryl/transport
import beryl/wire
import channel_readme_example_test
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import test_helper
import unitest

type Command {
  Block
  Ping
  Fail
  TrackAdditional
}

type Started {
  Started(process.Pid, socket.Sender(Command))
}

type Fixture {
  Fixture(
    sockets: beryl.Sockets,
    started: process.Subject(Started),
    entered: process.Subject(process.Subject(Nil)),
    acknowledged: process.Subject(Nil),
    frames: process.Subject(process.Subject(String)),
  )
}

@external(erlang, "beryl_router_ownership_test_ffi", "with_cleanup")
fn with_cleanup(action: fn() -> value, cleanup: fn() -> Nil) -> value

@external(erlang, "beryl_router_ownership_test_ffi", "guardian")
fn guardian(
  router: process.Pid,
  socket: process.Pid,
) -> Result(process.Pid, Nil)

@external(erlang, "beryl_router_ownership_test_ffi", "with_suspended")
fn with_suspended(pid: process.Pid, action: fn() -> value) -> value

@external(erlang, "beryl_supervisor_test_ffi", "active_child_count")
fn active_child_count(pid: process.Pid) -> Int

@external(erlang, "beryl_supervisor_test_ffi", "only_active_child")
fn only_active_child(pid: process.Pid) -> Result(process.Pid, Nil)

@external(erlang, "beryl_router_ownership_test_ffi", "topic_factory")
fn topic_factory(
  socket: process.Pid,
  socket_factory: process.Pid,
) -> Result(process.Pid, Nil)

fn drain(subject: process.Subject(message)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(Nil) -> Nil
  }
}

fn release_gates(gates: process.Subject(process.Subject(Nil))) -> Nil {
  case process.receive(gates, 0) {
    Ok(gate) -> {
      process.send(gate, Nil)
      release_gates(gates)
    }
    Error(Nil) -> Nil
  }
}

fn drain_frames(frames: process.Subject(process.Subject(String))) -> Nil {
  case process.receive(frames, 0) {
    Ok(subject) -> {
      drain(subject)
      drain_frames(frames)
    }
    Error(Nil) -> Nil
  }
}

fn with_fixture(block_init: Bool, action: fn(Fixture) -> Nil) -> Nil {
  with_presence_fixture(block_init, None, action)
}

fn with_presence_fixture(
  block_init: Bool,
  tracker: Option(presence.Presence),
  action: fn(Fixture) -> Nil,
) -> Nil {
  let started = process.new_subject()
  let entered = process.new_subject()
  let gates = process.new_subject()
  let acknowledged = process.new_subject()
  let frames = process.new_subject()
  let block = fn() {
    let gate = process.new_subject()
    // Keep an independent cleanup copy even after the test consumes entry.
    process.send(gates, gate)
    process.send(entered, gate)
    process.receive_forever(gate)
  }
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_max_connections_per_ip(2)
  let config = case tracker {
    None -> config
    Some(handle) -> beryl.with_presence_handle(config, handle)
  }
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      config,
      init: fn(info) {
        process.send(started, Started(process.self(), info.self))
        case block_init {
          True -> block()
          False -> Nil
        }
        #(Nil, [])
      },
      update: fn(model, input) {
        case input {
          socket.Info(Block) -> block()
          socket.Info(Ping) -> process.send(acknowledged, Nil)
          socket.Info(TrackAdditional) -> process.send(acknowledged, Nil)
          socket.Info(Fail) -> panic as "ownership callback failure"
          socket.Join(..) -> process.send(acknowledged, Nil)
          socket.Message(..) | socket.Binary(..) | socket.Closed(..) -> Nil
        }
        case input {
          socket.Join(topic, _, reference) -> {
            let effects = case tracker {
              None -> []
              Some(_) -> [
                socket.PresenceTrack(topic, "user", json.object([])),
              ]
            }
            socket.Next(model, [socket.AcceptJoin(reference, None), ..effects])
          }
          socket.Info(TrackAdditional) ->
            socket.Next(model, [
              socket.PresenceTrack("room:a", "old-only", json.object([])),
            ])
          socket.Info(Block)
          | socket.Info(Ping)
          | socket.Info(Fail)
          | socket.Message(..)
          | socket.Binary(..)
          | socket.Closed(..) -> socket.Next(model, [])
        }
      },
    )
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  process.unlink(root.pid)
  let assert Ok(factory) = beryl.app_socket_factory_pid(sockets)
  with_cleanup(
    fn() { action(Fixture(sockets, started, entered, acknowledged, frames)) },
    fn() {
      release_gates(gates)
      // Stop the whole fixture even if a failed assertion left init blocked.
      process.kill(root.pid)
      test_helper.wait_until(fn() { !process.is_alive(root.pid) }, 2000, 5)
      test_helper.wait_until(fn() { !process.is_alive(factory) }, 6000, 5)
      release_gates(gates)
      drain(started)
      drain(entered)
      drain(acknowledged)
      drain_frames(frames)
    },
  )
}

fn connect(fixture: Fixture, socket_id: String) -> Started {
  let frames = app_test_helper.connect(fixture.sockets, socket_id)
  process.send(fixture.frames, frames)
  let assert Ok(started) = process.receive(fixture.started, 1000)
  started
}

fn await_dead(pid: process.Pid) -> Nil {
  test_helper.wait_until(fn() { !process.is_alive(pid) }, 2000, 5)
  process.is_alive(pid) |> should.be_false
}

fn replacement(sockets: beryl.Sockets, old: process.Pid) -> process.Pid {
  test_helper.wait_until(
    fn() {
      case transport.runtime_pid(sockets) {
        Ok(pid) -> pid != old
        Error(Nil) -> False
      }
    },
    2000,
    5,
  )
  app_test_helper.runtime_pid(sockets)
}

/// Regression: the gate stays closed until fixture cleanup, after assertions.
pub fn blocked_update_router_death_test() -> Nil {
  use <- unitest.tag("serial")
  use fixture <- with_fixture(False)
  let sockets = fixture.sockets
  let router = app_test_helper.runtime_pid(sockets)
  let assert Ok(factory) = beryl.app_socket_factory_pid(sockets)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  let assert Ok(permit) =
    transport.acquire_connection_slot(sockets, "192.0.2.86")
  transport.bind_connection_slot(permit) |> should.equal(Ok(Nil))
  let Started(old_socket, old_sender) = connect(fixture, "same-id")
  socket.notify(old_sender, Block) |> should.equal(Ok(Nil))
  let assert Ok(_closed_gate) = process.receive(fixture.entered, 1000)
  process.kill(router)
  let _new_router = replacement(sockets, router)
  // Deliberately do not discover a guardian here: this must fail on the old
  // runtime at actor survival, not at absence of the proposed implementation.
  await_dead(old_socket)
  socket.notify(old_sender, Ping) |> should.be_error
  test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 5)
  beryl.app_socket_factory_pid(sockets) |> should.equal(Ok(factory))
  beryl.app_limiter_pid(sockets) |> should.equal(Ok(limiter))
  let assert Ok(second) =
    transport.acquire_connection_slot(sockets, "192.0.2.86")
  transport.bind_connection_slot(second) |> should.equal(Ok(Nil))
  transport.acquire_connection_slot(sockets, "192.0.2.86")
  |> should.be_error
  let Started(fresh_socket, fresh_sender) = connect(fixture, "same-id")
  process.is_alive(fresh_socket) |> should.be_true
  socket.notify(fresh_sender, Ping) |> should.equal(Ok(Nil))
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  app_test_helper.join(sockets, "same-id", "room:a", "join", "reply")
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  active_child_count(factory) |> should.equal(1)
  transport.release_connection_slot(permit)
  transport.release_connection_slot(second)
}

fn find_guardian(router: process.Pid, socket: process.Pid) -> process.Pid {
  test_helper.wait_until(
    fn() {
      case guardian(router, socket) {
        Ok(_) -> True
        Error(Nil) -> False
      }
    },
    1000,
    5,
  )
  let assert Ok(pid) = guardian(router, socket)
  test_helper.monitor_count(pid) |> should.equal(2)
  pid
}

/// A delayed guardian owns a PID, never a socket ID or replacement router.
pub fn delayed_guardian_preserves_same_id_replacement_test() -> Nil {
  use <- unitest.tag("serial")
  use fixture <- with_fixture(False)
  let sockets = fixture.sockets
  let router = app_test_helper.runtime_pid(sockets)
  let assert Ok(factory) = beryl.app_socket_factory_pid(sockets)
  let assert Ok(limiter) = beryl.app_limiter_pid(sockets)
  let Started(old_socket, old_sender) = connect(fixture, "same-id")
  socket.notify(old_sender, Block) |> should.equal(Ok(Nil))
  let assert Ok(_closed_gate) = process.receive(fixture.entered, 1000)
  let old_guardian = find_guardian(router, old_socket)
  let #(new_router, fresh_socket, fresh_sender, fresh_guardian) =
    with_suspended(old_guardian, fn() {
      process.kill(router)
      let new_router = replacement(sockets, router)
      let Started(fresh_socket, fresh_sender) = connect(fixture, "same-id")
      let fresh_guardian = find_guardian(new_router, fresh_socket)
      process.is_alive(old_socket) |> should.be_true
      active_child_count(factory) |> should.equal(2)
      #(new_router, fresh_socket, fresh_sender, fresh_guardian)
    })
  await_dead(old_socket)
  await_dead(old_guardian)
  socket.notify(old_sender, Ping) |> should.be_error
  beryl.app_socket_factory_pid(sockets) |> should.equal(Ok(factory))
  beryl.app_limiter_pid(sockets) |> should.equal(Ok(limiter))
  transport.runtime_pid(sockets) |> should.equal(Ok(new_router))
  process.is_alive(fresh_socket) |> should.be_true
  process.is_alive(fresh_guardian) |> should.be_true
  socket.notify(fresh_sender, Ping) |> should.equal(Ok(Nil))
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  app_test_helper.join(sockets, "same-id", "room:a", "join", "reply")
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  test_helper.wait_until(fn() { active_child_count(factory) == 1 }, 2000, 5)
  transport.socket_disconnected(sockets, "same-id")
  await_dead(fresh_socket)
  await_dead(fresh_guardian)
}

fn monitor_baseline(router: process.Pid) -> #(Int, Int) {
  #(test_helper.monitor_count(router), test_helper.monitored_by_count(router))
}

fn await_baseline(router: process.Pid, baseline: #(Int, Int)) -> Nil {
  test_helper.wait_until(fn() { monitor_baseline(router) == baseline }, 2000, 5)
  monitor_baseline(router) |> should.equal(baseline)
}

/// Socket-first exits must release the guardian's remaining router monitor.
pub fn disconnect_and_callback_failure_release_guardians_test() -> Nil {
  use <- unitest.tag("serial")
  use fixture <- with_fixture(False)
  let router = app_test_helper.runtime_pid(fixture.sockets)
  let baseline = monitor_baseline(router)
  let assert Ok(factory) = beryl.app_socket_factory_pid(fixture.sockets)
  list.each([False, True], fn(fail_callback) {
    let Started(socket_pid, sender) = connect(fixture, "socket-first")
    let guardian_pid = find_guardian(router, socket_pid)
    case fail_callback {
      True -> socket.notify(sender, Fail) |> should.equal(Ok(Nil))
      False -> transport.socket_disconnected(fixture.sockets, "socket-first")
    }
    await_dead(socket_pid)
    await_dead(guardian_pid)
    socket.notify(sender, Ping) |> should.be_error
    await_baseline(router, baseline)
    transport.runtime_pid(fixture.sockets) |> should.equal(Ok(router))
    test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 5)
  })
}

fn admit(fixture: Fixture, owner: process.Pid) -> Result(Nil, Nil) {
  transport.admit_socket(
    sockets: fixture.sockets,
    owner: owner,
    socket_id: "booting",
    send: fn(_) { Ok(Nil) },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
}

/// The guardian exists while init is blocked, before registration completes.
pub fn blocked_init_router_death_releases_guardian_test() -> Nil {
  use <- unitest.tag("serial")
  use fixture <- with_fixture(True)
  let router = app_test_helper.runtime_pid(fixture.sockets)
  let assert Ok(factory) = beryl.app_socket_factory_pid(fixture.sockets)
  let completed = process.new_subject()
  let connection =
    process.spawn_unlinked(fn() {
      process.send(completed, admit(fixture, router))
    })
  use <-
    with_cleanup(_, fn() {
      process.kill(connection)
      await_dead(connection)
      drain(completed)
    })
  let assert Ok(Started(socket_pid, sender)) =
    process.receive(fixture.started, 1000)
  let assert Ok(_closed_gate) = process.receive(fixture.entered, 1000)
  let guardian_pid = find_guardian(router, socket_pid)
  process.kill(router)
  let _new_router = replacement(fixture.sockets, router)
  await_dead(socket_pid)
  await_dead(guardian_pid)
  socket.notify(sender, Ping) |> should.be_error
  process.receive(completed, 2000) |> should.equal(Ok(Error(Nil)))
  test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 5)
}

/// Admission cancellation is cooperative once init returns, with no watcher
/// left behind and no extra monitor on the still-live router.
pub fn cancelled_blocked_init_releases_guardian_test() -> Nil {
  use <- unitest.tag("serial")
  use fixture <- with_fixture(True)
  let router = app_test_helper.runtime_pid(fixture.sockets)
  let baseline = monitor_baseline(router)
  let assert Ok(factory) = beryl.app_socket_factory_pid(fixture.sockets)
  let completed = process.new_subject()
  let connection =
    process.spawn_unlinked(fn() {
      process.send(completed, admit(fixture, router))
    })
  use <-
    with_cleanup(_, fn() {
      process.kill(connection)
      await_dead(connection)
      drain(completed)
    })
  let assert Ok(Started(socket_pid, sender)) =
    process.receive(fixture.started, 1000)
  let assert Ok(gate) = process.receive(fixture.entered, 1000)
  let guardian_pid = find_guardian(router, socket_pid)
  process.receive(completed, 2000) |> should.equal(Ok(Error(Nil)))
  process.send(gate, Nil)
  await_dead(socket_pid)
  await_dead(guardian_pid)
  socket.notify(sender, Ping) |> should.be_error
  await_baseline(router, baseline)
  test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 5)
}

fn presence_refs(handle: presence.Presence) -> List(String) {
  let assert Ok(entries) = presence.list(handle, "room:a")
  list.map(entries, fn(entry) {
    let assert Ok(reference) =
      json.parse(
        json.to_string(entry.meta),
        decode.at(["phx_ref"], decode.string),
      )
    reference
  })
  |> list.sort(string.compare)
}

fn await_presence_refs(
  handle: presence.Presence,
  references: List(String),
) -> Nil {
  let references = list.sort(references, string.compare)
  test_helper.wait_until(fn() { presence_refs(handle) == references }, 2000, 5)
  presence_refs(handle) |> should.equal(references)
}

/// Old runtime-owned refs disappear independently of the blocked callback;
/// neither a public ref nor a new owner's same-ID/key ref is swept.
pub fn delayed_guardian_preserves_replacement_presence_test() -> Nil {
  use <- unitest.tag("serial")
  let assert Ok(handle) = presence.start(presence.default_config("ownership"))
  let assert Ok(presence_pid) = process.subject_owner(presence.subject(handle))
  process.unlink(presence_pid)
  use <-
    with_cleanup(_, fn() {
      process.kill(presence_pid)
      await_dead(presence_pid)
    })
  let assert Ok(public_ref) =
    presence.track(handle, "room:a", "user", "same-id", json.object([]))
  use fixture <- with_presence_fixture(False, Some(handle))
  let sockets = fixture.sockets
  let router = app_test_helper.runtime_pid(sockets)
  let Started(old_socket, old_sender) = connect(fixture, "same-id")
  app_test_helper.join(sockets, "same-id", "room:a", "old", "old")
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() { list.length(presence_refs(handle)) == 2 },
    2000,
    5,
  )
  let assert [old_ref] =
    presence_refs(handle)
    |> list.filter(fn(reference) { reference != public_ref })
  // Same-ID/key tracks intentionally supersede earlier runtime refs across
  // owners. Keep another old-owner key to prove actual owner-death cleanup,
  // rather than mistaking replacement supersession for cleanup.
  socket.notify(old_sender, TrackAdditional) |> should.equal(Ok(Nil))
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  test_helper.wait_until(
    fn() { list.length(presence_refs(handle)) == 3 },
    2000,
    5,
  )
  let assert [old_only_ref] =
    presence_refs(handle)
    |> list.filter(fn(reference) {
      reference != public_ref && reference != old_ref
    })
  socket.notify(old_sender, Block) |> should.equal(Ok(Nil))
  let assert Ok(_closed_gate) = process.receive(fixture.entered, 1000)
  let old_guardian = find_guardian(router, old_socket)
  let #(fresh_socket, fresh_guardian, fresh_sender, fresh_ref) =
    with_suspended(old_guardian, fn() {
      process.kill(router)
      let new_router = replacement(sockets, router)
      let Started(fresh_socket, fresh_sender) = connect(fixture, "same-id")
      let fresh_guardian = find_guardian(new_router, fresh_socket)
      app_test_helper.join(sockets, "same-id", "room:a", "fresh", "fresh")
      process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
      test_helper.wait_until(
        fn() {
          let references = presence_refs(handle)
          list.length(references) == 3 && !list.contains(references, old_ref)
        },
        2000,
        5,
      )
      let assert [fresh_ref] =
        presence_refs(handle)
        |> list.filter(fn(reference) {
          reference != public_ref && reference != old_only_ref
        })
      await_presence_refs(handle, [public_ref, old_only_ref, fresh_ref])
      process.is_alive(old_socket) |> should.be_true
      #(fresh_socket, fresh_guardian, fresh_sender, fresh_ref)
    })
  await_dead(old_socket)
  await_dead(old_guardian)
  socket.notify(old_sender, Ping) |> should.be_error
  await_presence_refs(handle, [public_ref, fresh_ref])
  socket.notify(fresh_sender, Ping) |> should.equal(Ok(Nil))
  process.receive(fixture.acknowledged, 1000) |> should.equal(Ok(Nil))
  transport.socket_disconnected(sockets, "same-id")
  await_dead(fresh_socket)
  await_dead(fresh_guardian)
  await_presence_refs(handle, [public_ref])
  test_helper.wait_until(
    fn() {
      let assert Ok(current) = presence.queue_snapshot(handle)
      current.items == 0 && current.bytes == 0
    },
    2000,
    5,
  )
}

/// Reuse the README channel fixture to exercise the existing linked worker
/// topology. Suspending the socket makes cooperative RouterDown impossible.
pub fn router_death_reclaims_linked_topic_factory_and_worker_test() -> Nil {
  use <- unitest.tag("serial")
  let assert Ok(#(sockets, spec)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      channel_readme_example_test.room(),
    ])
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  process.unlink(root.pid)
  let assert Ok(factory) = beryl.app_socket_factory_pid(sockets)
  let frames = process.new_subject()
  use <-
    with_cleanup(_, fn() {
      process.kill(root.pid)
      await_dead(root.pid)
      test_helper.wait_until(fn() { !process.is_alive(factory) }, 6000, 5)
      drain(frames)
    })
  let router = app_test_helper.runtime_pid(sockets)
  transport.admit_socket(
    sockets: sockets,
    owner: router,
    socket_id: "channel",
    send: fn(frame) {
      process.send(frames, frame)
      Ok(Nil)
    },
    send_binary: fn(_) { Ok(Nil) },
    codec: None,
    seed: socket.empty_seed(),
    close: fn() { Nil },
  )
  |> should.equal(Ok(Nil))
  app_test_helper.join_ok(sockets, frames, "channel", "room:a", "join", "reply")
  let assert Ok(socket_pid) = only_active_child(factory)
  let assert Ok(topic_factory_pid) = topic_factory(socket_pid, factory)
  let assert Ok(worker) = only_active_child(topic_factory_pid)
  let guardian_pid = find_guardian(router, socket_pid)
  with_suspended(socket_pid, fn() {
    process.kill(router)
    let _new_router = replacement(sockets, router)
    await_dead(socket_pid)
    await_dead(guardian_pid)
    await_dead(topic_factory_pid)
    await_dead(worker)
  })
  test_helper.wait_until(fn() { active_child_count(factory) == 0 }, 2000, 5)
  beryl.app_socket_factory_pid(sockets) |> should.equal(Ok(factory))
}
