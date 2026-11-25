//// Server counterpart to the official Phoenix Channels chat tutorial.

import beryl/channel
import example_helper/payload
import gleam/json

/// Accept the public tutorial lobby and reject private rooms.
pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(context) {
    case context.topic {
      "room:lobby" ->
        channel.accept(Nil)
        |> channel.on_message(fn(state, message) {
          case message.event {
            "new_msg" ->
              case payload.string_field(message.payload, "body") {
                Ok(body) ->
                  channel.next(state, [
                    channel.broadcast(
                      "new_msg",
                      json.object([#("body", json.string(body))]),
                    ),
                    channel.discard_reply(message.reply),
                  ])
                Error(Nil) ->
                  channel.next(state, [
                    channel.reply_error(
                      message.reply,
                      json.object([
                        #("reason", json.string("body must be a string")),
                      ]),
                    ),
                  ])
              }
            _ -> channel.next(state, [channel.discard_reply(message.reply)])
          }
        })
      _ ->
        channel.reject(json.object([#("reason", json.string("unauthorized"))]))
    }
  })
}
