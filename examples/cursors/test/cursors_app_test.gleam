import beryl/socket
import cursors/app
import gleam/dynamic
import gleam/json
import gleam/list
import gleeunit/should

fn model() -> app.Model {
  app.Model(username: "Alice", color: "#abcdef")
}

fn reaction_payload(
  reaction: String,
  x: dynamic.Dynamic,
  y: dynamic.Dynamic,
) -> dynamic.Dynamic {
  dynamic.properties([
    #(dynamic.string("reaction"), dynamic.string(reaction)),
    #(dynamic.string("x"), x),
    #(dynamic.string("y"), y),
  ])
}

pub fn supported_reactions_broadcast_test() {
  ["👍", "❤️", "😂", "🎉", "🔥"]
  |> list.each(fn(reaction) {
    let #(_, effects) =
      app.update(
        "socket-1",
        "cursor:lobby",
        model(),
        "reaction",
        reaction_payload(reaction, dynamic.float(0.25), dynamic.float(0.75)),
      )

    let assert [socket.BroadcastFrom("cursor:lobby", "reaction", payload)] =
      effects
    json.to_string(payload)
    |> should.equal(
      "{\"reaction\":\"" <> reaction <> "\",\"x\":0.25,\"y\":0.75}",
    )
  })
}

pub fn integer_boundary_coordinates_broadcast_test() {
  let #(_, effects) =
    app.update(
      "socket-1",
      "cursor:lobby",
      model(),
      "reaction",
      reaction_payload("👍", dynamic.int(0), dynamic.int(1)),
    )

  let assert [socket.BroadcastFrom("cursor:lobby", "reaction", payload)] =
    effects
  json.to_string(payload)
  |> should.equal("{\"reaction\":\"👍\",\"x\":0.0,\"y\":1.0}")
}

pub fn invalid_reaction_payloads_are_dropped_test() {
  let missing_y =
    dynamic.properties([
      #(dynamic.string("reaction"), dynamic.string("👍")),
      #(dynamic.string("x"), dynamic.float(0.5)),
    ])
  let invalid_payloads = [
    reaction_payload("👎", dynamic.float(0.5), dynamic.float(0.5)),
    reaction_payload("👍", dynamic.float(-0.1), dynamic.float(0.5)),
    reaction_payload("👍", dynamic.float(0.5), dynamic.float(1.1)),
    reaction_payload("👍", dynamic.string("middle"), dynamic.float(0.5)),
    missing_y,
  ]

  invalid_payloads
  |> list.each(fn(payload) {
    let #(_, effects) =
      app.update("socket-1", "cursor:lobby", model(), "reaction", payload)
    effects |> should.equal([])
  })
}

pub fn cursor_move_behavior_is_unchanged_test() {
  let payload =
    dynamic.properties([
      #(dynamic.string("x"), dynamic.int(12)),
      #(dynamic.string("y"), dynamic.int(34)),
    ])
  let #(_, effects) =
    app.update("socket-1", "cursor:lobby", model(), "cursor_move", payload)

  let assert [socket.BroadcastFrom("cursor:lobby", "cursor_move", broadcast)] =
    effects
  json.to_string(broadcast)
  |> should.equal(
    "{\"socket_id\":\"socket-1\",\"x\":12,\"y\":34,\"username\":\"Alice\",\"color\":\"#abcdef\"}",
  )
}
