//// One process per accepted topic (#337).
////
//// Every joined channel runs in its own worker under a per-socket
//// supervisor, so the isolation boundaries match Phoenix's: a slow or
//// crashing callback affects one topic, a leave still delivers the replies
//// computed before it, and a socket's workers die with the socket. These
//// tests pin that topology through beryl's public transport SPI.

import beryl
import beryl/channel
import beryl/transport
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

pub type Poke {
  Poke
}

/// What a test channel reports as it runs.
type Report {
  /// The process a callback ran in.
  Ran(topic: String, callback: String, pid: process.Pid)
  /// `on_terminate` ran with this reason.
  Terminated(topic: String, reason: String)
}

/// A channel whose `on_message` sleeps for `slow_ms` before replying, and
/// whose `on_terminate` sleeps for `terminate_ms`.
fn sleepy(
  pattern: String,
  reports: process.Subject(Report),
  senders: process.Subject(channel.Sender(Poke)),
  slow_ms slow_ms: Int,
  terminate_ms terminate_ms: Int,
) -> channel.Handler {
  channel.handler(pattern, fn(context) {
    process.send(reports, Ran(context.topic, "join", process.self()))
    process.send(senders, context.self)
    channel.accept(Nil)
    |> channel.on_message(fn(_state, message) {
      process.send(reports, Ran(context.topic, "on_message", process.self()))
      process.sleep(slow_ms)
      case message.event {
        "quit" -> channel.close([])
        "silent" -> channel.next(Nil, [])
        "echo" ->
          channel.next(Nil, [
            channel.push("pong", json.string(context.topic)),
            channel.reply_ok(
              message.reply,
              json.object([#("from", json.string(context.topic))]),
            ),
          ])
        _ ->
          channel.next(Nil, [
            channel.reply_ok(
              message.reply,
              json.object([#("from", json.string(context.topic))]),
            ),
          ])
      }
    })
    |> channel.on_info(fn(_state, _poke) {
      process.send(reports, Ran(context.topic, "on_info", process.self()))
      channel.next(Nil, [channel.push("poked", json.string(context.topic))])
    })
    |> channel.on_terminate(fn(_state, reason) {
      process.sleep(terminate_ms)
      process.send(
        reports,
        Terminated(context.topic, helper.reason_name(reason)),
      )
      [channel.broadcast("left", json.string(context.topic))]
    })
  })
}

fn quick(
  pattern: String,
  reports: process.Subject(Report),
  senders: process.Subject(channel.Sender(Poke)),
) -> channel.Handler {
  sleepy(pattern, reports, senders, slow_ms: 0, terminate_ms: 0)
}

fn config() -> beryl.Config {
  beryl.config(wire.phoenix_codec()) |> beryl.with_heartbeat(timeout_ms: 60_000)
}

fn next_report(reports: process.Subject(Report)) -> Report {
  let assert Ok(report) = process.receive(reports, 1000) as "a report arrived"
  report
}

fn ran_pid(reports: process.Subject(Report), callback: String) -> process.Pid {
  let assert Ran(callback: got, pid: pid, ..) = next_report(reports)
    as "a callback ran"
  got |> should.equal(callback)
  pid
}

fn terminated(
  reports: process.Subject(Report),
  topic: String,
  reason: String,
) -> Nil {
  next_report(reports) |> should.equal(Terminated(topic, reason))
}

fn wait_until_dead(pid: process.Pid) -> Nil {
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(process.monitor(pid), fn(down) { down })
    |> process.selector_receive(1000)
    as "the process exited"
  Nil
}

// --- isolation ---------------------------------------------------------------

pub fn each_topic_runs_in_its_own_process_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels = helper.start(config(), [quick("room:*", reports, senders)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)

  let a = ran_pid(reports, "join")
  let b = ran_pid(reports, "join")
  a |> should.not_equal(b)
  let assert Ok(router) = transport.runtime_pid(channels)
  a |> should.not_equal(router)

  // Every later callback of a topic runs in that same process.
  helper.push(channels, "s1", "room:a", "ping", "r-3")
  ran_pid(reports, "on_message") |> should.equal(a)
  let _ = helper.recv(frames)
  Nil
}

pub fn a_slow_callback_on_one_topic_does_not_delay_another_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("slow:*", reports, senders, slow_ms: 400, terminate_ms: 0),
      quick("room:*", reports, senders),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "slow:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)

  helper.push(channels, "s1", "slow:a", "ping", "r-3")
  helper.push(channels, "s1", "room:b", "ping", "r-4")

  // The quick topic answers while the slow one is still sleeping, then
  // the slow one answers in its own time.
  let assert Ok(first) = process.receive(frames, 200) as "the quick reply"
  first |> string.contains("\"r-4\"") |> should.be_true
  let assert Ok(second) = process.receive(frames, 1000) as "the slow reply"
  second |> string.contains("\"r-3\"") |> should.be_true
}

pub fn a_slow_join_on_one_socket_does_not_block_another_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let handler =
    channel.handler("room:*", fn(context) {
      case context.topic {
        "room:slow" -> process.sleep(400)
        _ -> Nil
      }
      process.send(reports, Ran(context.topic, "join", process.self()))
      process.send(senders, context.self)
      channel.accept(Nil)
    })
  let channels = helper.start(config(), [handler])
  let slow = helper.connect(channels, "s1")
  let fast = helper.connect(channels, "s2")

  helper.join(channels, "s1", "room:slow", "jr-1", "r-1")
  helper.join(channels, "s2", "room:fast", "jr-1", "r-1")

  // Each socket has its own worker supervisor, so a join never queues
  // behind another socket's join.
  let assert Ok(_) = process.receive(fast, 200) as "the fast socket's join"
  let assert Ok(_) = process.receive(slow, 1000) as "the slow socket's join"
  Nil
}

// --- leave ordering ----------------------------------------------------------

pub fn a_reply_computed_before_a_leave_is_still_delivered_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 200, terminate_ms: 0),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let _ = ran_pid(reports, "join")

  // The push is in the worker's mailbox before the leave reaches it, so
  // its push and reply are computed first and delivered before the topic
  // closes — the ordering Phoenix's channel process gives for free.
  helper.push(channels, "s1", "room:a", "echo", "r-2")
  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")

  helper.recv(frames) |> string.contains("\"r-3\"") |> should.be_true
  let assert Ok(pushed) = process.receive(frames, 1000) as "the echo's push"
  pushed |> string.contains("\"pong\"") |> should.be_true
  let reply = helper.recv(frames)
  reply |> string.contains("\"r-2\"") |> should.be_true
  reply |> string.contains("\"from\":\"room:a\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  let _ = ran_pid(reports, "on_message")
  terminated(reports, "room:a", "normal")
}

pub fn a_leave_followed_immediately_by_a_rejoin_is_ordered_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 0, terminate_ms: 200),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let first = ran_pid(reports, "join")
  let assert Ok(stale) = process.receive(senders, 500)

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  helper.join(channels, "s1", "room:a", "jr-2", "r-3")

  // The rejoin waits for the old worker to terminate, then gets a fresh
  // worker; the wire sees leave ack, close, join ack in that order.
  helper.recv(frames) |> string.contains("\"r-2\"") |> should.be_true
  let assert Ok(close) = process.receive(frames, 1000) as "the close frame"
  close |> string.contains("phx_close") |> should.be_true
  terminated(reports, "room:a", "normal")
  let assert Ok(joined) = process.receive(frames, 1000) as "the rejoin ack"
  joined |> string.contains("\"r-3\"") |> should.be_true
  let second = ran_pid(reports, "join")
  second |> should.not_equal(first)
  let assert Ok(fresh) = process.receive(senders, 500)

  // The old join's sender reaches nothing; the new one works.
  channel.notify(stale, Poke)
  process.receive(reports, 100) |> should.be_error
  channel.notify(fresh, Poke)
  ran_pid(reports, "on_info") |> should.equal(second)
  helper.recv(frames) |> string.contains("poked") |> should.be_true
}

pub fn a_ref_left_unanswered_before_a_leave_is_dropped_by_the_close_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels = helper.start(config(), [quick("room:*", reports, senders)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let _ = ran_pid(reports, "join")

  // "silent" never answers r-2, so its ref is outstanding until the close.
  helper.push(channels, "s1", "room:a", "silent", "r-2")
  let _ = ran_pid(reports, "on_message")
  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")
  helper.recv(frames) |> string.contains("\"r-3\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  terminated(reports, "room:a", "normal")

  // A rejoin that reuses the same refs is answered, not refused as a
  // duplicate: the close dropped the old join's refs.
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let _ = ran_pid(reports, "join")
  helper.push(channels, "s1", "room:a", "ping", "r-2")
  let _ = ran_pid(reports, "on_message")
  let reply = helper.recv(frames)
  reply |> string.contains("\"r-2\"") |> should.be_true
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn a_message_behind_a_close_is_not_handled_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 200, terminate_ms: 0),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let _ = ran_pid(reports, "join")

  // "ping" reaches the worker's mailbox while "quit" is still running, so
  // it sits behind the close the channel asked for.
  helper.push(channels, "s1", "room:a", "quit", "r-2")
  helper.push(channels, "s1", "room:a", "ping", "r-3")
  let _ = ran_pid(reports, "on_message")

  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  terminated(reports, "room:a", "shutdown")
  // The closed channel ran no further callback and answered nothing.
  helper.recv_none(frames)
  process.receive(reports, 100) |> should.be_error
}

pub fn a_notify_from_join_is_served_after_the_join_is_indexed_test() -> Nil {
  let tracker = process.new_name("roster_tracker")
  let handler =
    channel.handler("room:*", fn(context) {
      // As a presence tracker would: the join asks itself to publish the
      // roster, and the publish goes through a third process.
      channel.notify(context.self, Poke)
      channel.accept(Nil)
      |> channel.on_info(fn(_state, _poke) {
        process.send(process.named_subject(tracker), context.topic)
        channel.stay(Nil)
      })
    })
  let channels = helper.start(config(), [handler])
  let _publisher =
    process.spawn_unlinked(fn() {
      let assert Ok(Nil) = process.register(process.self(), tracker)
      let assert Ok(topic) =
        process.receive(process.named_subject(tracker), 5000)
      let _ = beryl.broadcast(channels, topic, "roster", json.string("r"))
      Nil
    })
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  // The worker serves the join's own mail only once the socket has indexed
  // the join, so the third process's broadcast finds the subscriber.
  helper.recv(frames) |> string.contains("\"r-1\"") |> should.be_true
  let assert Ok(roster) = process.receive(frames, 1000) as "the roster"
  roster |> string.contains("\"roster\"") |> should.be_true
}

// --- worker death -------------------------------------------------------------

pub fn a_close_of_a_dead_worker_does_not_wait_for_the_terminate_timeout_test() -> Nil {
  let reports = process.new_subject()
  let terminating = process.new_subject()
  let handler =
    channel.handler("room:*", fn(context) {
      process.send(reports, Ran(context.topic, "join", process.self()))
      channel.accept(Nil)
      |> channel.on_terminate(fn(_state, _reason) {
        process.send(terminating, context.topic)
        process.sleep(300)
        []
      })
    })
  let channels = helper.start(config(), [handler])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)
  let _a = ran_pid(reports, "join")
  let b = ran_pid(reports, "join")

  // The teardown closes room:a first and parks on its `on_terminate`;
  // room:b's worker dies meanwhile, so its exit is queued behind the park.
  helper.disconnect(channels, "s1")
  let assert Ok("room:a") = process.receive(terminating, 1000)
    as "room:a is terminating"
  process.kill(b)
  wait_until_dead(b)

  // room:b's close finds the worker gone and completes at once instead of
  // waiting out the terminate timeout.
  helper.recv(frames) |> string.contains("room:a") |> should.be_true
  let assert Ok(close) = process.receive(frames, 500) as "room:b's close"
  close |> string.contains("room:b") |> should.be_true
  process.receive(terminating, 100) |> should.be_error
}

pub fn a_killed_worker_closes_only_its_topic_with_phx_error_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels = helper.start(config(), [quick("room:*", reports, senders)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)
  let a = ran_pid(reports, "join")
  let _b = ran_pid(reports, "join")

  process.kill(a)

  // The state died with the process, so `on_terminate` cannot run; the
  // client learns to rejoin from the error frame.
  let close = helper.recv(frames)
  close |> string.contains("phx_error") |> should.be_true
  close |> string.contains("room:a") |> should.be_true
  process.receive(reports, 100) |> should.be_error

  // The sibling topic and the socket are untouched, and the topic can be
  // joined again.
  helper.push(channels, "s1", "room:b", "ping", "r-3")
  let _ = ran_pid(reports, "on_message")
  helper.recv(frames) |> string.contains("\"r-3\"") |> should.be_true
  helper.join(channels, "s1", "room:a", "jr-3", "r-4")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
}

pub fn a_blocking_terminate_is_bounded_and_the_worker_killed_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 0, terminate_ms: 60_000),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let worker = ran_pid(reports, "join")

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  let _acknowledgement = helper.recv(frames)

  // The close waits for the worker up to the terminate timeout (5s), then
  // kills it and still sends the terminal frame.
  let assert Ok(close) = process.receive(frames, 7000) as "the close frame"
  close |> string.contains("phx_close") |> should.be_true
  wait_until_dead(worker)
  // The socket is still usable afterwards.
  helper.join(channels, "s1", "room:a", "jr-2", "r-3")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
}

// --- socket lifetime -----------------------------------------------------------

pub fn a_disconnect_terminates_busy_workers_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 300, terminate_ms: 0),
    ])
  let frames = helper.connect(channels, "s1")
  let peer = helper.connect(channels, "s2")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)
  helper.join(channels, "s2", "room:a", "jr-1", "r-1")
  let _ = helper.recv(peer)
  let a = ran_pid(reports, "join")
  let b = ran_pid(reports, "join")
  let _peer = ran_pid(reports, "join")

  helper.push(channels, "s1", "room:a", "ping", "r-3")
  let _ = ran_pid(reports, "on_message")
  helper.disconnect(channels, "s1")

  // The busy worker finishes its callback, then both topics terminate in
  // order and every worker of the socket is gone.
  terminated(reports, "room:a", "normal")
  terminated(reports, "room:b", "normal")
  helper.recv(peer) |> string.contains("\"left\"") |> should.be_true
  wait_until_dead(a)
  wait_until_dead(b)
}

pub fn stopping_beryl_runs_on_terminate_for_every_worker_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels = helper.start(config(), [quick("room:*", reports, senders)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _ = helper.recv(frames)
  let a = ran_pid(reports, "join")
  let b = ran_pid(reports, "join")

  beryl.stop(channels) |> should.be_ok

  terminated(reports, "room:a", "shutdown")
  terminated(reports, "room:b", "shutdown")
  wait_until_dead(a)
  wait_until_dead(b)
}

pub fn stopping_beryl_while_a_leave_is_parked_lets_on_terminate_finish_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels =
    helper.start(config(), [
      sleepy("room:*", reports, senders, slow_ms: 0, terminate_ms: 300),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _ = helper.recv(frames)
  let a = ran_pid(reports, "join")

  // The leave parks the socket on room:a's `on_terminate`; the stop lands
  // while it is still running. The callback finishes, its close still
  // answers the leave, and only then does the socket tear down.
  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")
  process.sleep(50)
  beryl.stop(channels) |> should.be_ok

  terminated(reports, "room:a", "normal")
  helper.recv(frames) |> string.contains("\"r-2\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  wait_until_dead(a)
}

pub fn many_topics_on_one_socket_each_get_a_worker_test() -> Nil {
  let reports = process.new_subject()
  let senders = process.new_subject()
  let channels = helper.start(config(), [quick("room:*", reports, senders)])
  let frames = helper.connect(channels, "s1")
  [1, 2, 3, 4, 5]
  |> list.map(fn(n) {
    let topic = "room:" <> int.to_string(n)
    helper.join(channels, "s1", topic, "jr-" <> int.to_string(n), "r")
    let _ = helper.recv(frames)
    ran_pid(reports, "join")
  })
  |> list.unique
  |> list.length
  |> should.equal(5)
}
