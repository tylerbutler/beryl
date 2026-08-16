//// Compiles the flagship channel-layer guide example from
//// `website/src/content/docs/guides/channels.md` — the room channel from
//// "The shape", the `child_spec` and transport wiring from "Starting a
//// channel system", and the handler-table check from "Routing rules" —
//// so the guide's supervised start shape cannot drift from the real API.
////
//// Two deliberate deviations from the published text: the guide splits the
//// two snippets across `src/my_app/room_channel.gleam` and
//// `src/my_app.gleam`, which are one module here, and the guide's `main`
//// binds a Mist listener to port 8000. This test builds the same request
//// handler without binding a port — it pins the types the guide shows, not
//// a live listener. Real listeners are covered by `wire_matrix_test`.

import beryl
import beryl/transport/server
import beryl/wire
import beryl_channels
import beryl_channels/channel
import beryl_mist as mist_transport
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/otp/static_supervisor
import gleeunit
import gleeunit/should
import mist

pub fn main() {
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

    channel.accept(state, callbacks())
    |> channel.with_reply(json.object([#("room", json.string(context.topic))]))
    |> channel.with_actions([
      channel.broadcast("joined", json.string(state.username)),
    ])
  })
}

fn callbacks() -> channel.Callbacks(State, Note) {
  channel.callbacks()
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
}

// ---------------------------------------------------------------------------
// guides/channels.md — "Starting a channel system" (src/my_app.gleam)
// ---------------------------------------------------------------------------

pub fn handlers() -> List(channel.Handler) {
  [room()]
}

fn handle_http(
  _req: request.Request(mist.Connection),
) -> response.Response(mist.ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}

/// The guide's `child_spec` call, its config, and the transport wiring it hands
/// the returned handle to, compiled and run.
pub fn documented_guide_child_spec_example_compiles_and_starts_test() {
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_frame_rate(per_second: 35, burst: 70)
    |> beryl.with_message_rate(per_second: 30, burst: 60)

  let assert Ok(#(sockets, spec)) =
    beryl_channels.child_spec(config, handlers: handlers())
    as "the guide's handler table builds"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the guide's supervision tree starts"

  // `sockets` is an ordinary core handle: the guide hands it straight to
  // `mist_transport.handler` alongside the guide's `handle_http` fallback.
  let _request_handler =
    mist_transport.handler(
      sockets,
      server.default_config("/socket/websocket"),
      handle_http,
    )

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
