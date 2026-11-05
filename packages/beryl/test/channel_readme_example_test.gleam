//// Exercises a standalone counter channel and its supervision tree.
//// The documentation snippet checker compiles the actual published quick starts.

import beryl
import beryl/channel
import beryl/wire
import gleam/json
import gleam/otp/static_supervisor
import gleeunit/should
import unitest

pub fn main() -> Nil {
  unitest.main()
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(_context) {
    channel.accept(0)
    |> channel.on_message(fn(count, message) {
      channel.next(count + 1, [
        channel.discard_reply(message.reply),
        channel.broadcast(message.event, json.int(count + 1)),
      ])
    })
  })
}

/// Start and stop a supervised counter channel.
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

  let assert Ok(_) =
    beryl.broadcast(sockets, "room:lobby", "announce", json.string("hello"))

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
