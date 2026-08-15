//// Compiles the module-doc example from `beryl_channels/channel` so the
//// documented shape cannot drift from the real API.

import beryl_channels/channel
import gleam/json
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

pub type Note {
  Announce(String)
}

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(info, topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        channel.continue_with(
          count + 1,
          channel.actions()
            |> channel.broadcast(message.event, json.int(count + 1)),
        )
      })
      |> channel.on_info(fn(count, note) {
        let Announce(text) = note
        channel.continue_with(
          count,
          channel.actions() |> channel.push("announce", json.string(text)),
        )
      })

    channel.notify(info.self, Announce("welcome to " <> topic))
    channel.accept(channel.joined(0, callbacks))
  })
}

pub fn documented_example_compiles_and_joins_test() {
  room() |> channel.pattern |> should.equal("room:*")
}
