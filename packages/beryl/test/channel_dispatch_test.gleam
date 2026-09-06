//// Integration coverage for the dispatch adapter: `child_spec` compiles
//// a handler table into beryl's `init`/`update` pair, and every
//// assertion below is made through beryl's public transport SPI, on real
//// wire frames, against a real running system.

import beryl
import beryl/channel
import beryl/socket
import beryl/transport
import beryl/wire
import channel_dispatch_helper as helper
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/string
import gleeunit/should

/// The room channel's private server-side message type. It is never named
/// by the router, the socket model, or the wire.
pub type Note {
  Announce(String)
  Farewell
  /// Report the process the `on_info` callback runs in.
  WhereAmI(process.Subject(process.Pid))
}

/// Everything a test channel reports back to the test process.
pub type Wiring {
  Wiring(
    /// Ordered lifecycle trace: `"join:<topic>"` and
    /// `"terminate:<topic>:<reason>:<state>"`.
    trace: process.Subject(String),
    /// The typed sender of each accepted join, in join order.
    senders: process.Subject(channel.Sender(Note)),
    /// The process each `join` callback ran in.
    pids: process.Subject(process.Pid),
  )
}

pub fn new_wiring() -> Wiring {
  Wiring(
    trace: process.new_subject(),
    senders: process.new_subject(),
    pids: process.new_subject(),
  )
}

// --- test channels ---------------------------------------------------------

/// A channel that reports which handler owns the topic and nothing else.
fn labelled_handler(pattern: String, label: String) -> channel.Handler {
  channel.handler(pattern, fn(_context) {
    channel.accept(Nil)
    |> channel.with_reply(json.object([#("handler", json.string(label))]))
  })
}

fn params_handler(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(context) {
    channel.accept(Nil)
    |> channel.with_reply(
      json.object([
        #("params", json.array(context.parameters, json.string)),
      ]),
    )
  })
}

fn optional_reply_handler() -> channel.Handler {
  channel.handler("reply:*", fn(_context) {
    channel.accept(Nil)
    |> channel.on_message(fn(state, message) {
      channel.next(state, [
        channel.reply_ok(message.reply, json.object([])),
        channel.push("after", json.object([])),
      ])
    })
  })
}

/// The main test channel: an `Int` counter with every callback wired up.
fn room_handler(wiring: Wiring) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    process.send(wiring.trace, "join:" <> context.topic)
    process.send(wiring.senders, context.self)
    process.send(wiring.pids, process.self())

    room_channel(0, wiring, context.topic)
    |> channel.with_reply(json.object([#("handler", json.string("room"))]))
  })
}

fn room_channel(
  state: Int,
  wiring: Wiring,
  topic: String,
) -> channel.JoinResult(Int, Note) {
  channel.accept(state)
  |> channel.on_message(on_message)
  |> channel.on_info(on_info)
  |> channel.on_terminate(fn(count, reason) {
    process.send(
      wiring.trace,
      "terminate:"
        <> topic
        <> ":"
        <> reason_name(reason)
        <> ":"
        <> int.to_string(count),
    )
    []
  })
}

fn on_message(count: Int, message: channel.Message) -> channel.Next(Int) {
  case message.event, message.reply {
    "echo", reply ->
      channel.next(count, [
        channel.reply_ok(reply, json.object([#("echoed", json.bool(True))])),
      ])
    "fail", reply ->
      channel.next(count, [
        channel.reply_error(reply, json.object([#("no", json.bool(True))])),
      ])
    "burst", _ ->
      channel.next(count, [
        channel.push("one", json.int(1)),
        channel.push("two", json.int(2)),
        channel.broadcast_from("three", json.int(3)),
        channel.broadcast("four", json.int(4)),
      ])
    "count", _ ->
      channel.next(count + 1, [
        channel.push("count", json.int(count + 1)),
      ])
    "leave", _ -> channel.close([channel.push("bye", json.int(count))])
    _, _ -> channel.stay(count)
  }
}

fn on_info(count: Int, note: Note) -> channel.Next(Int) {
  case note {
    Announce(text) ->
      channel.next(count + 1, [
        channel.push(
          "note",
          json.string(text <> "#" <> int.to_string(count + 1)),
        ),
      ])
    Farewell -> channel.close([channel.push("farewell", json.int(count))])
    WhereAmI(reply) -> {
      process.send(reply, process.self())
      channel.stay(count)
    }
  }
}

fn reason_name(reason: socket.StopReason) -> String {
  case reason {
    socket.Normal -> "normal"
    socket.Shutdown -> "shutdown"
    socket.HeartbeatTimeout -> "heartbeat_timeout"
    socket.Errored(detail) -> "errored:" <> detail
  }
}

// --- systems ---------------------------------------------------------------

fn start(handlers: List(channel.Handler)) -> beryl.Sockets {
  helper.start(beryl.config(wire.phoenix_codec()), handlers: handlers)
}

fn start_room() -> #(beryl.Sockets, Wiring, process.Subject(String)) {
  let wiring = new_wiring()
  let channels = start([room_handler(wiring)])
  let frames = helper.connect(channels, "s1")
  #(channels, wiring, frames)
}

fn joined_room(
  topic_name: String,
) -> #(beryl.Sockets, Wiring, process.Subject(String)) {
  let #(channels, wiring, frames) = start_room()
  helper.join(channels, "s1", topic_name, "jr-1", "r-1")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  helper.next_trace(wiring.trace) |> should.equal("join:" <> topic_name)
  #(channels, wiring, frames)
}

fn next_sender(wiring: Wiring) -> channel.Sender(Note) {
  let assert Ok(sender) = process.receive(wiring.senders, 500)
    as "a join reported its sender"
  sender
}

// --- handler selection -----------------------------------------------------

pub fn join_selects_the_first_matching_handler_test() -> Nil {
  let channels =
    start([
      labelled_handler("room:lobby", "lobby"),
      labelled_handler("room:*", "room"),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:lobby", "jr-1", "r-1")
  helper.recv(frames)
  |> string.contains("\"handler\":\"lobby\"")
  |> should.be_true

  helper.join(channels, "s1", "room:other", "jr-2", "r-2")
  helper.recv(frames)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true
}

pub fn registration_order_decides_overlapping_patterns_test() -> Nil {
  let channels =
    start([
      labelled_handler("room:*", "room"),
      labelled_handler("room:lobby", "lobby"),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:lobby", "jr-1", "r-1")
  helper.recv(frames)
  |> string.contains("\"handler\":\"room\"")
  |> should.be_true
}

pub fn a_multi_segment_pattern_only_matches_its_own_shape_test() -> Nil {
  let channels =
    start([
      labelled_handler("document:*:ops", "ops"),
      labelled_handler("*", "catch_all"),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "document:42:ops", "jr-1", "r-1")
  helper.recv(frames)
  |> string.contains("\"handler\":\"ops\"")
  |> should.be_true

  // A topic of a different shape falls through to the next pattern in
  // registration order rather than being forced onto the first.
  helper.join(channels, "s1", "document:42", "jr-2", "r-2")
  helper.recv(frames)
  |> string.contains("\"handler\":\"catch_all\"")
  |> should.be_true

  helper.join(channels, "s1", "anything", "jr-3", "r-3")
  helper.recv(frames)
  |> string.contains("\"handler\":\"catch_all\"")
  |> should.be_true
}

pub fn join_context_contains_wildcard_captures_in_pattern_order_test() -> Nil {
  let channels =
    start([
      params_handler("room:lobby"),
      params_handler("document:*:*"),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:lobby", "jr-1", "r-1")
  helper.recv(frames) |> string.contains("\"params\":[]") |> should.be_true

  helper.join(channels, "s1", "document:tenant-a:42", "jr-2", "r-2")
  helper.recv(frames)
  |> string.contains("\"params\":[\"tenant-a\",\"42\"]")
  |> should.be_true
}

pub fn a_join_can_be_accepted_without_a_reply_payload_test() -> Nil {
  let channels =
    start([
      channel.handler("room:*", fn(_context) { channel.accept(Nil) }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  // The join is still acknowledged; it simply carries no response body.
  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("\"response\":{}") |> should.be_true
}

pub fn unmatched_topic_is_rejected_with_the_documented_reason_test() -> Nil {
  let #(channels, wiring, frames) = start_room()

  helper.join(channels, "s1", "other:1", "jr-1", "r-1")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply
  |> string.contains("{\"reason\":\"unmatched topic\"}")
  |> should.be_true

  // No handler ran, so no channel exists to terminate later.
  helper.no_trace(wiring.trace)
}

pub fn a_rejecting_handler_reports_its_own_reason_test() -> Nil {
  let channels =
    start([
      channel.handler("room:*", fn(_context) {
        channel.reject(json.object([#("reason", json.string("forbidden"))]))
      }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("forbidden") |> should.be_true
}

pub fn a_rejected_join_leaves_no_live_channel_test() -> Nil {
  let events = process.new_subject()
  let channels =
    start([
      channel.handler("room:*", fn(_context) {
        process.send(events, "join")
        channel.reject(json.object([#("reason", json.string("forbidden"))]))
      }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _rejection = helper.recv(frames)
  let assert Ok("join") = process.receive(events, 500) as "the handler ran"

  // Nothing was stored for the topic, so a later message reaches no
  // channel and the core answers it as an unjoined topic.
  helper.push(channels, "s1", "room:a", "echo", "r-2")
  helper.recv(frames)
  |> string.contains("{\"reason\":\"unmatched topic\"}")
  |> should.be_true
  process.receive(events, 100) |> should.be_error
}

// --- client messages -------------------------------------------------------

pub fn optional_reply_actions_handle_none_and_some_on_the_wire_test() -> Nil {
  let channels = start([optional_reply_handler()])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "reply:a", "jr-1", "r-1")
  let _join_reply = helper.recv(frames)

  helper.route(channels, "s1", "[null,null,\"reply:a\",\"go\",{}]")
  let refless = helper.recv(frames)
  refless |> string.contains("\"after\"") |> should.be_true
  refless |> string.contains("phx_reply") |> should.be_false
  helper.recv_none(frames)

  helper.push(channels, "s1", "reply:a", "go", "r-2")
  helper.recv(frames) |> string.contains("phx_reply") |> should.be_true
  helper.recv(frames) |> string.contains("\"after\"") |> should.be_true
}

pub fn client_messages_reach_the_live_channel_test() -> Nil {
  let #(channels, _wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "echo", "r-2")
  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"ok\"") |> should.be_true
  reply |> string.contains("\"echoed\":true") |> should.be_true
  reply |> string.contains("r-2") |> should.be_true

  helper.push(channels, "s1", "room:a", "fail", "r-3")
  let error_reply = helper.recv(frames)
  error_reply |> string.contains("\"status\":\"error\"") |> should.be_true
  error_reply |> string.contains("r-3") |> should.be_true
}

pub fn channel_state_advances_across_messages_test() -> Nil {
  let #(channels, _wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "count", "r-2")
  helper.recv(frames) |> string.contains("\"count\",1") |> should.be_true

  helper.push(channels, "s1", "room:a", "count", "r-3")
  helper.recv(frames) |> string.contains("\"count\",2") |> should.be_true
}

pub fn each_topic_keeps_its_own_state_test() -> Nil {
  let #(channels, wiring, frames) = start_room()
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")
  helper.next_trace(wiring.trace) |> should.equal("join:room:b")

  helper.push(channels, "s1", "room:a", "count", "r-3")
  helper.recv(frames)
  |> string.contains("\"room:a\",\"count\",1")
  |> should.be_true

  helper.push(channels, "s1", "room:b", "count", "r-4")
  helper.recv(frames)
  |> string.contains("\"room:b\",\"count\",1")
  |> should.be_true
}

pub fn actions_are_applied_in_order_on_the_channel_topic_test() -> Nil {
  let #(channels, _wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "burst", "r-2")

  // `broadcast_from` excludes this socket, so only one, two and four
  // reach it — in exactly the order they were added.
  let first = helper.recv(frames)
  first |> string.contains("\"room:a\",\"one\"") |> should.be_true
  let second = helper.recv(frames)
  second |> string.contains("\"room:a\",\"two\"") |> should.be_true
  let third = helper.recv(frames)
  third |> string.contains("\"room:a\",\"four\"") |> should.be_true
}

pub fn raw_binary_frames_are_ignored_test() -> Nil {
  let wiring = new_wiring()
  let channels =
    helper.start(beryl.config(helper.text_only_codec()), handlers: [
      room_handler(wiring),
    ])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")

  helper.route_binary(channels, "s1", <<1, 2, 3>>)
  helper.recv_none(frames)

  helper.push(channels, "s1", "room:a", "count", "r-2")
  helper.recv(frames) |> string.contains("\"count\",1") |> should.be_true
}

// --- termination -----------------------------------------------------------

pub fn close_applies_actions_then_kicks_the_topic_test() -> Nil {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "leave", "r-2")

  helper.recv(frames) |> string.contains("\"bye\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.next_trace(wiring.trace)
  |> should.equal("terminate:room:a:shutdown:0")
  helper.no_trace(wiring.trace)
}

pub fn a_client_leave_terminates_the_channel_once_test() -> Nil {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.leave(channels, "s1", "room:a", "jr-1", "r-2")

  let _leave_reply = helper.recv(frames)
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:0")
  helper.no_trace(wiring.trace)
}

pub fn a_disconnect_terminates_every_channel_once_test() -> Nil {
  let #(channels, wiring, frames) = start_room()
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")
  helper.next_trace(wiring.trace) |> should.equal("join:room:b")

  helper.disconnect(channels, "s1")

  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:0")
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:b:normal:0")
  helper.no_trace(wiring.trace)
}

pub fn a_disconnect_after_a_leave_does_not_terminate_twice_test() -> Nil {
  let #(channels, wiring, frames) = start_room()
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_a = helper.recv(frames)
  helper.join(channels, "s1", "room:b", "jr-2", "r-2")
  let _join_b = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")
  helper.next_trace(wiring.trace) |> should.equal("join:room:b")

  helper.leave(channels, "s1", "room:a", "jr-1", "r-3")
  let _leave_reply = helper.recv(frames)
  let _close = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:0")

  helper.disconnect(channels, "s1")

  // Only the topic that is still joined terminates: termination happens
  // exactly once per accepted join, never once per teardown path.
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:b:normal:0")
  helper.no_trace(wiring.trace)
}

// --- duplicate rejoin ------------------------------------------------------

pub fn a_rejoin_terminates_the_previous_instance_first_test() -> Nil {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "count", "r-2")
  let _count = helper.recv(frames)

  helper.join(channels, "s1", "room:a", "jr-2", "r-2")

  // Core order: the previous instance closes normally with the state it
  // had reached, and only then does a fresh instance join.
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:1")
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")

  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true

  // The fresh instance starts from its own initial state.
  helper.push(channels, "s1", "room:a", "count", "r-3")
  helper.recv(frames) |> string.contains("\"count\",1") |> should.be_true
}

// --- typed server-side sends -----------------------------------------------

pub fn typed_info_reaches_the_channels_on_info_test() -> Nil {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  channel.notify(sender, Announce("hello"))

  helper.recv(frames) |> string.contains("\"hello#1\"") |> should.be_true
}

pub fn every_send_delivers_exactly_one_payload_in_order_test() -> Nil {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  channel.notify(sender, Announce("a"))
  channel.notify(sender, Announce("b"))

  helper.recv(frames) |> string.contains("\"a#1\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"b#2\"") |> should.be_true
  helper.recv_none(frames)
}

pub fn sends_from_another_process_are_delivered_test() -> Nil {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)
  let done = process.new_subject()

  process.spawn_unlinked(fn() {
    channel.notify(sender, Announce("remote"))
    process.send(done, Nil)
  })

  let assert Ok(Nil) = process.receive(done, 500) as "the sender process ran"
  helper.recv(frames) |> string.contains("\"remote#1\"") |> should.be_true
}

pub fn a_stale_generations_send_is_never_delivered_test() -> Nil {
  let #(channels, wiring, frames) = joined_room("room:a")
  let stale = next_sender(wiring)

  helper.join(channels, "s1", "room:a", "jr-2", "r-2")
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:0")
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")
  let _close = helper.recv(frames)
  let _rejoin_reply = helper.recv(frames)
  let fresh = next_sender(wiring)

  // The stale sender belongs to the closed generation: its envelope is
  // dropped before the sealed thunk runs, so its payload reaches neither
  // generation.
  channel.notify(stale, Announce("stale"))
  helper.recv_none(frames)

  // ...and the live generation is unpolluted.
  channel.notify(fresh, Announce("fresh"))
  helper.recv(frames) |> string.contains("\"fresh#1\"") |> should.be_true
}

/// A rejected join still consumes a generation. If it did not, the next
/// join on the same topic would reuse the rejected join's generation and
/// its `Sender` would deliver into a channel that never admitted it.
pub fn a_rejected_joins_sender_cannot_reach_a_later_accepted_join_test() -> Nil {
  let senders = process.new_subject()
  let channels =
    start([
      channel.handler("room:*", fn(context) {
        process.send(senders, context.self)
        case decode.run(context.payload, decode.at(["admit"], decode.bool)) {
          Ok(True) ->
            channel.accept(0)
            |> channel.on_info(fn(count, note) {
              let assert Announce(text) = note as "only announcements"
              channel.next(count + 1, [
                channel.push("note", json.string(text)),
              ])
            })
          Ok(False) | Error(_) ->
            channel.reject(json.object([#("reason", json.string("no"))]))
        }
      }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join_with(channels, "s1", "room:a", "jr-1", "r-1", "{\"admit\":false}")
  helper.recv(frames)
  |> string.contains("\"status\":\"error\"")
  |> should.be_true
  let rejected_sender = next_sender_of(senders)

  helper.join_with(channels, "s1", "room:a", "jr-2", "r-2", "{\"admit\":true}")
  helper.recv(frames) |> string.contains("\"status\":\"ok\"") |> should.be_true
  let live_sender = next_sender_of(senders)

  channel.notify(rejected_sender, Announce("ghost"))
  helper.recv_none(frames)

  channel.notify(live_sender, Announce("real"))
  helper.recv(frames) |> string.contains("\"real\"") |> should.be_true
}

fn next_sender_of(
  senders: process.Subject(channel.Sender(Note)),
) -> channel.Sender(Note) {
  let assert Ok(sender) = process.receive(senders, 500)
    as "a join reported its sender"
  sender
}

pub fn a_send_to_a_closed_channel_is_never_delivered_test() -> Nil {
  let #(channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  helper.push(channels, "s1", "room:a", "leave", "r-2")
  let _bye = helper.recv(frames)
  let _close = helper.recv(frames)
  helper.next_trace(wiring.trace)
  |> should.equal("terminate:room:a:shutdown:0")

  channel.notify(sender, Announce("gone"))
  helper.recv_none(frames)
}

pub fn an_info_result_can_close_the_channel_test() -> Nil {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  channel.notify(sender, Farewell)

  helper.recv(frames) |> string.contains("\"farewell\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.next_trace(wiring.trace)
  |> should.equal("terminate:room:a:shutdown:0")
}

/// The join callback and `on_info` must run in the *same* process: the
/// typed hand-off `channel.handler` creates is owned by whichever process
/// ran the join, and only that process may read from it. This pins the
/// process-affinity seam the layer depends on — and pins that the process
/// is the topic's own worker, not the runtime's router, so one socket's
/// callbacks can never stall another's (#334). `channel_worker_test` pins
/// that different topics get different workers (#337).
pub fn join_and_info_run_in_the_topics_own_process_test() -> Nil {
  let #(channels, wiring, _frames) = joined_room("room:a")
  let sender = next_sender(wiring)
  let assert Ok(join_pid) = process.receive(wiring.pids, 500)
    as "the join reported its process"
  let answers = process.new_subject()

  channel.notify(sender, WhereAmI(answers))

  let assert Ok(info_pid) = process.receive(answers, 500)
    as "on_info reported its process"
  info_pid |> should.equal(join_pid)

  let assert Ok(runtime) = transport.runtime_pid(channels)
    as "the runtime is running"
  join_pid |> should.not_equal(runtime)
}
