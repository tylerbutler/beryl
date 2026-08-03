//// Coverage for the package entry points: handler validation runs before
//// anything is started, core errors are nested verbatim, and a
//// `child_spec` system really dispatches once its supervisor is running.

import beryl
import beryl/wire
import beryl_channels
import beryl_channels/channel
import dispatch_helpers as helper
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

pub fn child_spec_rejects_an_invalid_pattern_before_building_test() {
  beryl_channels.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
    ok_handler("room:*"),
    ok_handler(""),
  ])
  |> should.equal(
    Error(
      beryl_channels.ChildSpecInvalidHandlers(beryl_channels.InvalidPattern(
        "",
        "pattern cannot be empty",
      )),
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
