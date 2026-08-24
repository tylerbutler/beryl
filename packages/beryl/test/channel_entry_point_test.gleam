//// Coverage for the channel entry point: handler validation runs before
//// anything is started, core errors are nested verbatim, and a
//// `child_spec` system really dispatches once its supervisor is running.

import beryl
import beryl/channel
import beryl/topic
import beryl/wire
import channel_dispatch_helper as helper
import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should

fn ok_handler(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(_context) {
    channel.accept(Nil)
    |> channel.with_reply(json.object([#("handler", json.string(pattern))]))
  })
}

// --- validation happens first ----------------------------------------------

pub fn child_spec_rejects_an_invalid_pattern_before_building_test() {
  channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
    ok_handler("room:*"),
    ok_handler(""),
  ])
  |> should.equal(Error(channel.InvalidPattern("", topic.EmptyTopic)))
}

pub fn child_spec_rejects_an_invalid_handler_table_test() {
  let result =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      ok_handler("room:*"),
      ok_handler("room:*"),
    ])

  result
  |> should.equal(Error(channel.DuplicatePattern("room:*")))
}

pub fn child_spec_nests_the_core_config_error_verbatim_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(timeout_ms: 1)

  channel.child_spec(config, handlers: [ok_handler("room:*")])
  |> should.equal(Error(channel.InvalidConfig(beryl.HeartbeatTimeoutTooLow(2))))
}

// --- a supervised system dispatches ----------------------------------------

pub fn child_spec_dispatches_once_its_supervisor_runs_test() {
  let assert Ok(#(channels, spec)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      ok_handler("room:*"),
    ])
    as "the handler table and config are valid"

  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the supervision tree starts"

  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")

  helper.recv(frames)
  |> string.contains("\"handler\":\"room:*\"")
  |> should.be_true
}

/// The explicit child-spec path and the shared supervised test helper must
/// produce the same channel lifecycle.
pub fn child_spec_runs_the_same_lifecycle_through_both_supervised_paths_test() {
  let helper_started = process.new_subject()
  let supervised = process.new_subject()

  let direct =
    helper.start(beryl.config(wire.phoenix_codec()), handlers: [
      lifecycle_handler(helper_started),
    ])

  let assert Ok(#(channels, spec)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      lifecycle_handler(supervised),
    ])
    as "the handler table and config are valid"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the supervision tree starts"

  let direct_frames = drive_lifecycle(direct)
  let supervised_frames = drive_lifecycle(channels)

  supervised_frames |> should.equal(direct_frames)
  collect(supervised) |> should.equal(collect(helper_started))
}

/// Join, exchange a message, then disconnect — the whole lifecycle, as a
/// list of the frame shapes it produced.
fn drive_lifecycle(channels: beryl.Sockets) -> List(String) {
  let frames = helper.connect(channels, "s1")
  helper.join(channels, "s1", "room:a", "jr-1", "r-1")
  let join_reply = helper.recv(frames)
  helper.push(channels, "s1", "room:a", "ping", "r-2")
  let pong = helper.recv(frames)
  helper.disconnect(channels, "s1")
  let close = helper.recv(frames)
  helper.recv_none(frames)
  [join_reply, pong, close]
}

/// A channel that traces its whole lifecycle.
fn lifecycle_handler(trace: process.Subject(String)) -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let result =
      channel.accept(Nil)
      |> channel.on_message(fn(state, message) {
        process.send(trace, "message:" <> message.event)
        channel.next(state, [channel.push("pong", json.int(1))])
      })
      |> channel.on_terminate(fn(_state, reason) {
        process.send(trace, "terminate:" <> helper.reason_name(reason))
        []
      })
    process.send(trace, "join:" <> context.topic)
    result
    |> channel.with_reply(json.object([#("handler", json.string("room:*"))]))
  })
}

fn collect(trace: process.Subject(String)) -> List(String) {
  case process.receive(trace, 100) {
    Error(Nil) -> []
    Ok(line) -> [line, ..collect(trace)]
  }
}
