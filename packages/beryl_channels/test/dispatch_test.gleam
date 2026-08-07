//// Integration coverage for the dispatch adapter: `child_spec` compiles
//// a handler table into beryl's `init`/`update` pair, and every
//// assertion below is made through beryl's public transport SPI, on real
//// wire frames, against a real running system.

import beryl
import beryl/socket
import beryl/transport
import beryl/wire
import beryl/wire/codec
import beryl_channels/channel
import dispatch_helpers as helper
import gleam/bit_array
import gleam/erlang/process
import gleam/int
import gleam/json
import gleam/option
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
  channel.handler(pattern, fn(_info, _topic, _payload) {
    channel.accept_with(
      channel.joined(Nil, channel.callbacks()),
      json.object([#("handler", json.string(label))]),
    )
  })
}

/// The main test channel: an `Int` counter with every callback wired up.
fn room_handler(wiring: Wiring) -> channel.Handler {
  channel.handler("room:*", fn(info, topic, _payload) {
    process.send(wiring.trace, "join:" <> topic)
    process.send(wiring.senders, info.self)
    process.send(wiring.pids, process.self())

    channel.accept_with(
      channel.joined(0, room_callbacks(wiring, topic)),
      json.object([#("handler", json.string("room"))]),
    )
  })
}

fn room_callbacks(
  wiring: Wiring,
  topic: String,
) -> channel.Callbacks(Int, Note) {
  channel.callbacks()
  |> channel.on_message(on_message)
  |> channel.on_binary(fn(count, data) {
    channel.continue_with(
      count,
      channel.actions()
        |> channel.push("binary", json.int(bit_array.byte_size(data))),
    )
  })
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
  })
}

fn on_message(count: Int, message: channel.Message) -> channel.Next(Int) {
  case message.event, message.reply {
    "echo", option.Some(ref) ->
      channel.continue_with(
        count,
        channel.actions()
          |> channel.reply_ok(ref, json.object([#("echoed", json.bool(True))])),
      )
    "fail", option.Some(ref) ->
      channel.continue_with(
        count,
        channel.actions()
          |> channel.reply_error(ref, json.object([#("no", json.bool(True))])),
      )
    "burst", _ ->
      channel.continue_with(
        count,
        channel.actions()
          |> channel.push("one", json.int(1))
          |> channel.push("two", json.int(2))
          |> channel.broadcast_from("three", json.int(3))
          |> channel.broadcast("four", json.int(4)),
      )
    "count", _ ->
      channel.continue_with(
        count + 1,
        channel.actions() |> channel.push("count", json.int(count + 1)),
      )
    "leave", _ ->
      channel.close_with(
        channel.actions() |> channel.push("bye", json.int(count)),
      )
    "halt", _ -> channel.stop_socket(socket.Normal)
    _, _ -> channel.continue(count)
  }
}

fn on_info(count: Int, note: Note) -> channel.Next(Int) {
  case note {
    Announce(text) ->
      channel.continue_with(
        count + 1,
        channel.actions()
          |> channel.push(
            "note",
            json.string(text <> "#" <> int.to_string(count + 1)),
          ),
      )
    Farewell ->
      channel.close_with(
        channel.actions() |> channel.push("farewell", json.int(count)),
      )
    WhereAmI(reply) -> {
      process.send(reply, process.self())
      channel.continue(count)
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

pub fn join_selects_the_first_matching_handler_test() {
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

pub fn registration_order_decides_overlapping_patterns_test() {
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

pub fn unmatched_topic_is_rejected_with_the_documented_reason_test() {
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

pub fn a_rejecting_handler_reports_its_own_reason_test() {
  let channels =
    start([
      channel.handler("room:*", fn(_info, _topic, _payload) {
        channel.reject(json.object([#("reason", json.string("forbidden"))]))
      }),
    ])
  let frames = helper.connect(channels, "s1")

  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  let reply = helper.recv(frames)
  reply |> string.contains("\"status\":\"error\"") |> should.be_true
  reply |> string.contains("forbidden") |> should.be_true
}

// --- client messages -------------------------------------------------------

pub fn client_messages_reach_the_live_channel_test() {
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

pub fn channel_state_advances_across_messages_test() {
  let #(channels, _wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "count", "r-2")
  helper.recv(frames) |> string.contains("\"count\",1") |> should.be_true

  helper.push(channels, "s1", "room:a", "count", "r-3")
  helper.recv(frames) |> string.contains("\"count\",2") |> should.be_true
}

pub fn each_topic_keeps_its_own_state_test() {
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

pub fn actions_are_applied_in_order_on_the_channel_topic_test() {
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

pub fn binary_frames_reach_the_live_channel_test() {
  // The Phoenix framing minus its binary decoder, so raw binary frames
  // take the per-topic fan-out path and arrive as `Binary` inputs.
  let text_only =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: wire.reply_json,
      encode_push: wire.push,
      encode_heartbeat_reply: wire.heartbeat_reply,
    )
    |> codec.with_close_encoder(wire.channel_close)
    |> codec.with_error_encoder(wire.channel_error)

  let wiring = new_wiring()
  let channels =
    helper.start(beryl.config(text_only), handlers: [room_handler(wiring)])
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let _join_reply = helper.recv(frames)
  helper.next_trace(wiring.trace) |> should.equal("join:room:a")

  helper.route_binary(channels, "s1", <<1, 2, 3, 4, 5>>)

  helper.recv(frames) |> string.contains("\"binary\",5") |> should.be_true
}

// --- termination -----------------------------------------------------------

pub fn close_applies_actions_then_kicks_the_topic_test() {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "leave", "r-2")

  helper.recv(frames) |> string.contains("\"bye\"") |> should.be_true
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.next_trace(wiring.trace)
  |> should.equal("terminate:room:a:shutdown:0")
  helper.no_trace(wiring.trace)
}

pub fn a_client_leave_terminates_the_channel_once_test() {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.route(channels, "s1", "[\"jr-1\",\"r-2\",\"room:a\",\"phx_leave\",{}]")

  let _leave_reply = helper.recv(frames)
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.next_trace(wiring.trace) |> should.equal("terminate:room:a:normal:0")
  helper.no_trace(wiring.trace)
}

pub fn a_disconnect_terminates_every_channel_once_test() {
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

pub fn stop_socket_tears_down_the_socket_test() {
  let #(channels, wiring, frames) = joined_room("room:a")

  helper.push(channels, "s1", "room:a", "halt", "r-2")

  helper.next_trace(wiring.trace)
  |> string.starts_with("terminate:room:a:")
  |> should.be_true
  helper.no_trace(wiring.trace)

  // Terminal close frame for the joined topic, then nothing more: the
  // socket is gone, so a later frame reaches no channel.
  helper.recv(frames) |> string.contains("phx_close") |> should.be_true
  helper.push(channels, "s1", "room:a", "count", "r-3")
  helper.recv_none(frames)
}

// --- duplicate rejoin ------------------------------------------------------

pub fn a_rejoin_terminates_the_previous_instance_first_test() {
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

pub fn typed_info_reaches_the_channels_on_info_test() {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  channel.notify(sender, Announce("hello"))

  helper.recv(frames) |> string.contains("\"hello#1\"") |> should.be_true
}

pub fn every_send_delivers_exactly_one_payload_in_order_test() {
  let #(_channels, wiring, frames) = joined_room("room:a")
  let sender = next_sender(wiring)

  channel.notify(sender, Announce("a"))
  channel.notify(sender, Announce("b"))

  helper.recv(frames) |> string.contains("\"a#1\"") |> should.be_true
  helper.recv(frames) |> string.contains("\"b#2\"") |> should.be_true
  helper.recv_none(frames)
}

pub fn sends_from_another_process_are_delivered_test() {
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

pub fn a_stale_generations_send_is_never_delivered_test() {
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

pub fn a_send_to_a_closed_channel_is_never_delivered_test() {
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

pub fn an_info_result_can_close_the_channel_test() {
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
/// process-affinity seam the adapter depends on.
pub fn join_and_info_run_in_the_same_runtime_process_test() {
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
  join_pid |> should.equal(runtime)
}
