//// Compiles the flagship channel-layer guide example from
//// `website/src/content/docs/guides/channels.md` — the room channel from
//// "The shape", the `child_spec` from "Starting a channel system", and the
//// handler-table check from "Routing rules" —
//// so the guide's supervised start shape cannot drift from the real API.
////
//// Two deliberate deviations from the published text: the guide splits the
//// two snippets across `src/my_app/room_channel.gleam` and
//// `src/my_app.gleam`, which are one module here, and transport wiring is
//// covered by the transport packages.

import beryl
import beryl/channel
import beryl/wire
import gleam/json
import gleam/otp/static_supervisor
import gleeunit
import gleeunit/should

pub fn main() -> Nil {
  gleeunit.main()
}

// ---------------------------------------------------------------------------
// guides/channels.md — "The shape" (src/my_app/room_channel.gleam)
// ---------------------------------------------------------------------------

/// This channel's private state — one value per joined topic.
type State {
  State(room_id: String, username: String, sent: Int)
}

/// This channel's server-side message type.
type Note {
  Tick(Int)
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(context: channel.JoinContext(Note)) {
    let state =
      State(room_id: context.topic, username: context.socket_id, sent: 0)

    channel.accept(state)
    |> channel.on_message(fn(state: State, message: channel.Message) {
      channel.next(State(..state, sent: state.sent + 1), [
        channel.broadcast_from(message.event, json.int(state.sent + 1)),
      ])
    })
    |> channel.on_info(fn(state: State, note: Note) {
      let Tick(at) = note
      channel.next(state, [channel.push("tick", json.int(at))])
    })
    |> channel.on_terminate(fn(state: State, _reason) {
      [channel.broadcast("left", json.string(state.username))]
    })
    |> channel.with_reply(json.object([#("room", json.string(context.topic))]))
    |> channel.with_actions([
      channel.broadcast("joined", json.string(state.username)),
    ])
  })
}

// ---------------------------------------------------------------------------
// guides/channels.md — "Starting a channel system" (src/my_app.gleam)
// ---------------------------------------------------------------------------

pub fn handlers() -> List(channel.Handler) {
  [room()]
}

/// The guide's `child_spec` call and config, compiled and run.
pub fn documented_guide_child_spec_example_compiles_and_starts_test() -> Nil {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)

  let assert Ok(#(sockets, spec)) =
    channel.child_spec(config, handlers: handlers())
    as "the guide's handler table builds"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the guide's supervision tree starts"

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
