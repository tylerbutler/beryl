//// Compiles the quick-start example from `packages/beryl_channels/README.md`
//// — the package's Hex landing page — so the first code a new user copies
//// cannot drift from the real API.
////
//// One deliberate deviation from the published text: the README's entry
//// point is `pub fn main()`, which is the gleeunit runner's name here, so
//// its body lives in the test function below instead.

import beryl
import beryl/wire
import beryl_channels
import beryl_channels/channel
import gleam/json
import gleam/otp/static_supervisor
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(_info, _topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        channel.continue_with(
          count + 1,
          channel.actions()
            |> channel.broadcast(message.event, json.int(count + 1)),
        )
      })

    channel.accept(channel.joined(0, callbacks))
  })
}

/// The README's `main`, compiled and run.
pub fn readme_quick_start_compiles_and_starts_test() {
  let assert Ok(#(sockets, spec)) =
    beryl_channels.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      room(),
    ])
    as "the README handler table builds"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the README supervision tree starts"

  beryl.broadcast(sockets, "room:lobby", "announce", json.string("hello"))

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
