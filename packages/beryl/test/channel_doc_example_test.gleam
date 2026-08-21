//// Compiles the module-doc examples from `beryl/channel` and
//// `beryl/channel` so the documented shapes cannot drift from
//// the real API.

import beryl
import beryl/channel
import beryl/wire
import gleam/json
import gleam/otp/static_supervisor
import gleeunit/should
import vouch

pub fn main() {
  vouch.main()
}

pub type Note {
  Announce(String)
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(context) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        channel.next(count + 1, [
          channel.broadcast(message.event, json.int(count + 1)),
        ])
      })
      |> channel.on_info(fn(count, note) {
        let Announce(text) = note
        channel.next(count, [
          channel.push("announce", json.string(text)),
        ])
      })
      |> channel.on_terminate(fn(_count, _reason) {
        [channel.broadcast("left", json.string(context.topic))]
      })

    channel.notify(context.self, Announce("later, on this topic"))
    channel.accept(0, callbacks)
    |> channel.with_actions([
      channel.push("welcome", json.string(context.topic)),
    ])
  })
}

pub fn documented_example_compiles_and_joins_test() {
  room() |> channel.pattern |> should.equal("room:*")
}

/// The `beryl/channel` module-doc entry-point example, compiled and run
/// so the documented shape cannot drift from the real API either.
pub fn documented_child_spec_example_compiles_and_starts_test() {
  let handlers = [room()]

  let assert Ok(#(sockets, spec)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: handlers)
    as "the documented handler table builds"
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
    as "the documented supervision tree starts"

  beryl.broadcast(sockets, "room:lobby", "announce", json.string("hi"))

  beryl.stop(sockets) |> should.equal(Ok(Nil))
}
