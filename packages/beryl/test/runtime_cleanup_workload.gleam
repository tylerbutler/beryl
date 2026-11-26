//// Opt-in router-only reduction fixture. Run with `gleam run -m
//// runtime_cleanup_workload`, not as part of the ordinary test suite.
//// No wall-clock/capacity claims. All setup and global verification are
//// deliberately outside the measured interval.

import app_test_helper
import beryl
import beryl/overload
import beryl/runtime
import beryl/snapshot
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/work_queue
import envoy
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/otp/system
import gleam/result
import gleam/string
import gleeunit/should
import test_helper

pub type Mode {
  NormalClose
  KilledActor
  OwnerExit
  TelemetryKilledActor
}

pub type Axis {
  UnrelatedActors
  UnrelatedTopics
}

pub type Config {
  Config(
    populations: List(Int),
    departing_batch: Int,
    repeats: Int,
    gleam_version: String,
    hardware: String,
  )
}

pub type Fixture {
  Fixture(
    sockets: beryl.Sockets,
    router: process.Pid,
    queue: work_queue.Queue(runtime.Message(Nil)),
    closed: process.Subject(String),
  )
}

pub type Connection {
  Connection(
    id: String,
    actor: process.Pid,
    frames: process.Subject(String),
    owner_stop: process.Subject(Nil),
    owner: process.Pid,
    owner_monitor: process.Monitor,
  )
}

type Sample {
  Sample(axis: Axis, mode: Mode, population: Int, raw_reductions: List(Int))
}

@external(erlang, "beryl_runtime_cleanup_test_ffi", "reductions")
fn reductions(pid: process.Pid) -> Int

@external(erlang, "beryl_runtime_cleanup_test_ffi", "target_present")
fn target_present(queue: work_queue.Queue(message), id: String) -> Bool

@external(erlang, "beryl_runtime_cleanup_test_ffi", "router_queue")
fn router_queue(router: process.Pid) -> work_queue.Queue(runtime.Message(Nil))

@external(erlang, "beryl_runtime_cleanup_test_ffi", "with_root")
fn with_root(root: process.Pid, action: fn() -> value) -> value

@external(erlang, "beryl_router_ownership_test_ffi", "with_cleanup")
fn with_cleanup(action: fn() -> value, cleanup: fn() -> Nil) -> value

@external(erlang, "beryl_runtime_cleanup_test_ffi", "metadata")
fn metadata() -> #(String, String, String, String, Int, Int, Int, Int)

/// Fixed, bounded default workload; repeats are independent fresh apps.
pub fn default_config() -> Config {
  Config(
    populations: [0, 100, 1000],
    departing_batch: 4,
    repeats: 5,
    gleam_version: envoy.get("BERYL_CLEANUP_GLEAM_VERSION")
      |> result.unwrap("not supplied"),
    hardware: envoy.get("BERYL_CLEANUP_HARDWARE")
      |> result.unwrap("not supplied; see VM architecture and logical CPUs"),
  )
}

/// Start a linked fixture app and always stop its complete supervisor tree.
/// Init may be gated by a regression; ordinary workload init is trivial.
pub fn with_fixture(
  telemetry_enabled: Bool,
  init: fn(socket.ConnectInfo(Nil)) -> #(Nil, List(socket.Effect)),
  action: fn(Fixture) -> value,
) -> value {
  let assert Ok(limits) = overload.limits(items: 64, bytes: 1_048_576)
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_router_queue_limits(limits)
    |> beryl.with_max_joined_topics_per_socket(1002)
    |> beryl.with_heartbeat(3_600_000)
  let config = case telemetry_enabled {
    True -> beryl.with_telemetry(config)
    False -> config
  }
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(config, init:, update: app_test_helper.accepting_update)
  let assert Ok(root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  with_root(root.pid, fn() {
    let router = app_test_helper.runtime_pid(sockets)
    let fixture =
      Fixture(sockets, router, router_queue(router), process.new_subject())
    action(fixture)
  })
}

/// Every socket has a dedicated, linked admission owner. Exit it normally
/// through its private subject, or explicitly stop it after another lifecycle.
pub fn connect(fixture: Fixture, id: String) -> Connection {
  let frames = process.new_subject()
  let ready = process.new_subject()
  let closed = fixture.closed
  let owner =
    process.spawn(fn() {
      let stop = process.new_subject()
      transport.admit_socket(
        sockets: fixture.sockets,
        owner: fixture.router,
        socket_id: id,
        send: fn(frame) {
          process.send(frames, frame)
          Ok(Nil)
        },
        send_binary: fn(_) { Ok(Nil) },
        codec: None,
        seed: socket.empty_seed(),
        close: fn() { process.send(closed, id) },
      )
      |> should.equal(Ok(Nil))
      process.send(ready, stop)
      process.receive_forever(stop)
    })
  let monitor = process.monitor(owner)
  let assert Ok(stop) = process.receive(ready, 2000)
  Connection(id, socket_actor(fixture.router, id), frames, stop, owner, monitor)
}

@external(erlang, "beryl_test_process_ffi", "socket_actor")
fn socket_actor(router: process.Pid, id: String) -> process.Pid

/// Join using the real transport path and consume its exact per-socket reply.
pub fn join(fixture: Fixture, connection: Connection, topic: String) -> Nil {
  app_test_helper.join_ok(
    fixture.sockets,
    connection.frames,
    connection.id,
    topic,
    topic,
    topic,
  )
}

/// Read exact counts only outside reduction intervals.
pub fn counts(fixture: Fixture) -> #(Int, Int, Int) {
  let assert Ok(value) = snapshot.get(fixture.sockets)
  #(
    snapshot.connected_sockets(value),
    snapshot.joined_socket_topic_pairs(value),
    snapshot.active_topics(value),
  )
}

/// Wait for eventual index publication and then assert exact counts.
pub fn await_counts(fixture: Fixture, expected: #(Int, Int, Int)) -> Nil {
  test_helper.wait_until(fn() { counts(fixture) == expected }, 3000, 2)
  counts(fixture) |> should.equal(expected)
}

/// Stop and reap the dedicated owner; consume only its correlated monitor.
pub fn stop_owner(connection: Connection) -> Nil {
  process.send(connection.owner_stop, Nil)
  process.new_selector()
  |> process.select_specific_monitor(connection.owner_monitor, fn(down) { down })
  |> process.selector_receive(2000)
  |> should.be_ok
  process.demonitor_process(connection.owner_monitor)
}

/// Observe each real terminal target removal using only batch-local ETS rows.
/// OTP suspension afterwards is the completion barrier: it can be handled
/// only AFTER the currently executing runtime callback returns.
pub fn await_removed(fixture: Fixture, connections: List(Connection)) -> Nil {
  test_helper.wait_until(
    fn() {
      list.all(connections, fn(connection) {
        !target_present(fixture.queue, connection.id)
      })
    },
    3000,
    1,
  )
}

fn departure(
  fixture: Fixture,
  connections: List(Connection),
  mode: Mode,
) -> Nil {
  list.each(connections, fn(connection) {
    case mode {
      NormalClose ->
        transport.socket_disconnected(fixture.sockets, connection.id)
      KilledActor | TelemetryKilledActor -> process.kill(connection.actor)
      OwnerExit -> process.send(connection.owner_stop, Nil)
    }
  })
}

fn measure(fixture: Fixture, departing: List(Connection), mode: Mode) -> Int {
  system.suspend(fixture.router)
  with_cleanup(
    fn() {
      let before = reductions(fixture.router)
      system.resume(fixture.router)
      departure(fixture, departing, mode)
      await_removed(fixture, departing)
      system.suspend(fixture.router)
      reductions(fixture.router) - before
    },
    fn() { system.resume(fixture.router) },
  )
}

fn numbered(prefix: String, count: Int) -> List(String) {
  int.range(0, count, [], fn(ids, index) {
    [prefix <> int.to_string(index), ..ids]
  })
  |> list.reverse
}

fn sample(axis: Axis, mode: Mode, population: Int, batch: Int) -> Int {
  let output = process.new_subject()
  // Isolation also covers linked owners and the app if an assertion fails.
  test_helper.with_isolated_caller(120_000, fn() {
    with_fixture(
      mode == TelemetryKilledActor,
      app_test_helper.accepting_init,
      fn(fixture) {
        let monitor_baseline = test_helper.monitor_count(fixture.router)
        let background = case axis {
          UnrelatedActors ->
            numbered("background-", population)
            |> list.map(fn(id) { connect(fixture, id) })
          UnrelatedTopics -> {
            // Exactly ONE background actor, even at population zero. Only the
            // number of unrelated topic entries varies along this axis.
            let host = connect(fixture, "topic-host")
            numbered("room:unrelated-", population)
            |> list.each(fn(topic) { join(fixture, host, topic) })
            [host]
          }
        }
        let peer = connect(fixture, "healthy")
        join(fixture, peer, "room:shared")
        let departing =
          numbered("departing-", batch)
          |> list.map(fn(id) {
            let connection = connect(fixture, id)
            join(fixture, connection, "room:shared")
            join(fixture, connection, "room:exclusive-" <> id)
            connection
          })
        let unrelated_pairs = case axis {
          UnrelatedActors -> 0
          UnrelatedTopics -> population
        }
        let background_count = list.length(background)
        await_counts(fixture, #(
          background_count + 1 + batch,
          unrelated_pairs + 1 + 2 * batch,
          unrelated_pairs + 1 + batch,
        ))
        let measured = measure(fixture, departing, mode)
        // Everything below, including router snapshots and peer fan-out, is
        // excluded. This is semantic evidence in addition to, not instead of,
        // the actual router reduction delta.
        await_counts(fixture, #(
          background_count + 1,
          unrelated_pairs + 1,
          unrelated_pairs + 1,
        ))
        beryl.broadcast(
          fixture.sockets,
          "room:shared",
          "cleanup-probe",
          json.null(),
        )
        |> should.equal(Ok(Nil))
        let assert Ok(frame) = process.receive(peer.frames, 1000)
        frame |> string.contains("\"cleanup-probe\"") |> should.be_true
        list.each(departing, fn(connection) {
          stop_owner(connection)
          test_helper.wait_until(
            fn() { !process.is_alive(connection.actor) },
            2000,
            1,
          )
        })
        let closed_ids =
          list.map(departing, fn(_) {
            let assert Ok(id) = process.receive(fixture.closed, 2000)
            id
          })
        closed_ids
        |> list.sort(string.compare)
        |> should.equal(
          departing
          |> list.map(fn(connection) { connection.id })
          |> list.sort(string.compare),
        )
        process.receive(fixture.closed, 0) |> should.equal(Error(Nil))
        test_helper.wait_until(
          fn() {
            test_helper.monitor_count(fixture.router)
            == monitor_baseline + 2 * { background_count + 1 }
          },
          2000,
          1,
        )
        beryl.stop(fixture.sockets) |> should.equal(Ok(Nil))
        list.each([peer, ..background], stop_owner)
        process.send(output, measured)
      },
    )
  })
  let assert Ok(measured) = process.receive(output, 1000)
  measured
}

fn mode_name(mode: Mode) -> String {
  case mode {
    NormalClose -> "normal_close"
    KilledActor -> "killed_actor"
    OwnerExit -> "owner_exit"
    TelemetryKilledActor -> "telemetry_killed_actor"
  }
}

fn axis_name(axis: Axis) -> String {
  case axis {
    UnrelatedActors -> "unrelated_actors"
    UnrelatedTopics -> "unrelated_topics"
  }
}

fn percentile(sorted: List(Int), percent: Int) -> Int {
  let rank = { list.length(sorted) * percent + 99 } / 100
  let assert Ok(value) = sorted |> list.drop(rank - 1) |> list.first
  value
}

fn median(values: List(Int)) -> Int {
  let sorted = list.sort(values, int.compare)
  let assert Ok(value) =
    sorted |> list.drop(list.length(sorted) / 2) |> list.first
  value
}

fn sample_json(sample: Sample) -> json.Json {
  let sorted = list.sort(sample.raw_reductions, int.compare)
  let assert Ok(minimum) = list.first(sorted)
  let assert Ok(maximum) = list.last(sorted)
  json.object([
    #("axis", json.string(axis_name(sample.axis))),
    #("mode", json.string(mode_name(sample.mode))),
    #("population", json.int(sample.population)),
    #("raw_router_reductions", json.array(sample.raw_reductions, json.int)),
    #("median", json.int(median(sorted))),
    #("minimum", json.int(minimum)),
    #("maximum", json.int(maximum)),
    #("spread", json.int(maximum - minimum)),
    #("p95", json.int(percentile(sorted, 95))),
    #("p99", json.int(percentile(sorted, 99))),
  ])
}

/// Emit raw data before asserting the PRESELECTED growth bound. No automatic
/// retries, adaptive allowance, or changing the bound after observing data.
/// Config accepts odd repeats 3..9, batch 1..8, and sorted populations 0..1000.
pub fn run(config: Config) -> Nil {
  should.be_true(
    config.repeats >= 3 && config.repeats <= 9 && config.repeats % 2 == 1,
  )
  should.be_true(config.departing_batch >= 1 && config.departing_batch <= 8)
  should.be_true(list.length(config.populations) >= 2)
  should.be_true(list.length(config.populations) <= 3)
  config.populations
  |> list.each(fn(population) {
    should.be_true(population >= 0 && population <= 1000)
  })
  config.populations |> should.equal(list.sort(config.populations, int.compare))
  let modes = [NormalClose, KilledActor, OwnerExit, TelemetryKilledActor]
  let axes = [UnrelatedActors, UnrelatedTopics]
  let samples =
    list.flat_map(axes, fn(axis) {
      list.flat_map(modes, fn(mode) {
        list.map(config.populations, fn(population) {
          // One unrecorded full lifecycle warm-up for every configuration.
          let _warmup = sample(axis, mode, population, config.departing_batch)
          let raw =
            list.repeat(Nil, config.repeats)
            |> list.map(fn(_) {
              sample(axis, mode, population, config.departing_batch)
            })
          Sample(axis, mode, population, raw)
        })
      })
    })
  let #(vm, otp, architecture, os, schedulers, online, logical, word_bytes) =
    metadata()
  let report =
    json.object([
      #("fixture", json.string("router_cleanup_reductions_v1")),
      #("vm", json.string(vm)),
      #("otp", json.string(otp)),
      #("gleam", json.string(config.gleam_version)),
      #("hardware", json.string(config.hardware)),
      #("architecture", json.string(architecture)),
      #("os_family", json.string(os)),
      #("schedulers", json.int(schedulers)),
      #("schedulers_online", json.int(online)),
      #("logical_processors_available", json.int(logical)),
      #("word_bytes", json.int(word_bytes)),
      #("populations", json.array(config.populations, json.int)),
      #("departing_batch", json.int(config.departing_batch)),
      #("memberships_per_departing_socket", json.int(2)),
      #("repeats", json.int(config.repeats)),
      #("warmups_per_configuration", json.int(1)),
      #("router_queue_items", json.int(64)),
      #("router_queue_bytes", json.int(1_048_576)),
      #("heartbeat_ms", json.int(3_600_000)),
      #("growth_multiplier", json.int(2)),
      #("growth_fixed_allowance_reductions", json.int(2000)),
      #(
        "percentile_method",
        json.string("nearest rank; descriptive, not tail guarantees"),
      ),
      #("samples", json.array(samples, sample_json)),
    ])
  io.println(json.to_string(report))
  list.each(axes, fn(axis) {
    list.each(modes, fn(mode) {
      let group =
        list.filter(samples, fn(sample) {
          sample.axis == axis && sample.mode == mode
        })
      let assert Ok(smallest) = list.first(group)
      let assert Ok(largest) = list.last(group)
      should.be_true(
        median(largest.raw_reductions)
        <= 2 * median(smallest.raw_reductions) + 2000,
      )
    })
  })
}

/// Runnable opt-in entry point; the unit test runner does not discover it.
pub fn main() -> Nil {
  run(default_config())
}
