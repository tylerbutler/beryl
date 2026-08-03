//// Coverage for the package entry points: handler validation runs before
//// anything is started, core errors are nested verbatim, and a
//// `child_spec` system really dispatches once its supervisor is running.

import beryl
import beryl/wire
import beryl_channels
import beryl_channels/channel
import dispatch_helpers as helper
import gleam/erlang/process
import gleam/json
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should

fn ok_handler(pattern: String) -> channel.Handler {
  channel.handler(pattern, fn(_info, _topic, _payload) {
    channel.accept_with(
      channel.joined(Nil, channel.callbacks()),
      json.object([#("handler", json.string(pattern))]),
    )
  })
}

// --- validation happens first ----------------------------------------------

pub fn start_rejects_an_invalid_pattern_before_starting_test() {
  beryl_channels.start(beryl.config(wire.phoenix_codec()), handlers: [
    ok_handler("room:*"),
    ok_handler(""),
  ])
  |> should.equal(
    Error(
      beryl_channels.InvalidHandlers(beryl_channels.InvalidPattern(
        "",
        "pattern cannot be empty",
      )),
    ),
  )
}

pub fn start_rejects_duplicate_patterns_before_starting_test() {
  beryl_channels.start(beryl.config(wire.phoenix_codec()), handlers: [
    ok_handler("room:*"),
    ok_handler("room:*"),
  ])
  |> should.equal(
    Error(
      beryl_channels.InvalidHandlers(beryl_channels.DuplicatePattern("room:*")),
    ),
  )
}

pub fn start_nests_the_core_start_error_verbatim_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(interval_ms: 1000, timeout_ms: 1)

  beryl_channels.start(config, handlers: [ok_handler("room:*")])
  |> should.equal(
    Error(
      beryl_channels.SocketStartFailed(
        beryl.InvalidConfig(beryl.HeartbeatTimeoutTooLow(2)),
      ),
    ),
  )
}

pub fn child_spec_rejects_an_invalid_handler_table_test() {
  let result =
    beryl_channels.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      ok_handler("room:*"),
      ok_handler("room:*"),
    ])

  result
  |> should.equal(
    Error(
      beryl_channels.ChildSpecInvalidHandlers(beryl_channels.DuplicatePattern(
        "room:*",
      )),
    ),
  )
}

pub fn child_spec_nests_the_core_config_error_verbatim_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(interval_ms: 1000, timeout_ms: 1)

  beryl_channels.child_spec(config, handlers: [ok_handler("room:*")])
  |> should.equal(
    Error(
      beryl_channels.ChildSpecInvalidConfig(beryl.HeartbeatTimeoutTooLow(2)),
    ),
  )
}

// --- a supervised system dispatches ----------------------------------------

pub fn child_spec_dispatches_once_its_supervisor_runs_test() {
  let assert Ok(#(channels, spec)) =
    beryl_channels.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
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

/// The same handler table must behave identically whichever entry point
/// started it: `child_spec` differs only in who owns the process.
pub fn a_supervised_system_runs_the_same_lifecycle_as_a_started_one_test() {
  let started = process.new_subject()
  let supervised = process.new_subject()

  let assert Ok(direct) =
    beryl_channels.start(beryl.config(wire.phoenix_codec()), handlers: [
      lifecycle_handler(started),
    ])
    as "the handler table is valid"

  let assert Ok(#(channels, spec)) =
    beryl_channels.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
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
  collect(supervised) |> should.equal(collect(started))
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
  channel.handler("room:*", fn(_info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(state, message) {
        process.send(trace, "message:" <> message.event)
        channel.continue_with(
          state,
          channel.actions() |> channel.push("pong", json.int(1)),
        )
      })
      |> channel.on_terminate(fn(_state, reason) {
        process.send(trace, "terminate:" <> helper.reason_name(reason))
      })
    process.send(trace, "join:" <> topic)
    channel.accept_with(
      channel.joined(Nil, callbacks),
      json.object([#("handler", json.string("room:*"))]),
    )
  })
}

fn collect(trace: process.Subject(String)) -> List(String) {
  case process.receive(trace, 100) {
    Error(Nil) -> []
    Ok(line) -> [line, ..collect(trace)]
  }
}
