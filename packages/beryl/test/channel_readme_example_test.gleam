//// Compiles the channel quick-start from `packages/beryl/README.md` so the
//// first code a new user copies
//// cannot drift from the real API.
////
//// One deliberate deviation from the published text: the README's entry
//// point is `pub fn main()`, which is the gleeunit runner's name here, so
//// its body lives in the test function below instead.

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

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(_context) {
    channel.accept(0)
    |> channel.on_message(fn(count, message) {
      channel.next(count + 1, [
        channel.broadcast(message.event, json.int(count + 1)),
      ])
    })
  })
}

/// The README's `main`, compiled and run.
pub fn readme_quick_start_compiles_and_starts_test() -> Nil {
  let assert Ok(#(sockets, child_specification)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      room(),
    ])
    as "the README handler table builds"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child_specification)
    |> static_supervisor.start()
    as "the README supervision tree starts"

  beryl.broadcast(sockets, "room:lobby", "announce", json.string("hello"))

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
