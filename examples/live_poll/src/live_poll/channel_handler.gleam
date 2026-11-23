import beryl/channel
import beryl/overload
import beryl/socket.{type ReplyReference}
import gleam/io
import gleam/json
import gleam/option.{type Option}
import live_poll/poll
import live_poll/store
import live_poll/timer

pub type PollInfo {
  ClosePoll
}

type GuideInfo {
  Ready(String)
}

type ServerEvent {
  StateChanged(poll.Poll)
  PollClosed(poll.Poll)
  GuideTip(text: String, delivery: Int)
}

fn encode_event(event: ServerEvent) -> #(String, json.Json) {
  case event {
    StateChanged(state) -> #("poll_state", poll.to_json(state))
    PollClosed(state) -> #("poll_closed", poll.to_json(state))
    GuideTip(text, delivery) -> #(
      "tip",
      json.object([
        #("text", json.string(text)),
        #("delivery", json.int(delivery)),
      ]),
    )
  }
}

pub fn handlers(
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> List(channel.Handler) {
  [poll_channel(polls, clock, duration_ms), guide_channel()]
}

fn poll_channel(
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> channel.Handler {
  channel.handler("poll:*", fn(context) {
    case poll.room_name(context.topic) {
      Error(Nil) ->
        channel.reject(json.object([#("reason", json.string("unknown_topic"))]))
      Ok(room) -> {
        // The store monitors this worker; cleanup also happens if it is killed.
        let generation = store.join(polls, room)
        timer.after(clock, duration_ms, fn() {
          case channel.notify(context.self, ClosePoll) {
            Ok(Nil) -> Nil
            Error(error) ->
              io.println_error(
                "[live_poll] timer notification rejected: "
                <> overload.describe(error),
              )
          }
        })

        channel.accept(room)
        |> channel.on_decoded_message(
          decode: poll.decode_command,
          handle: fn(room, command, reply) {
            handle_command(polls, room, command, reply)
          },
          on_error: handle_invalid_message,
        )
        |> channel.on_info(fn(room, message) {
          let ClosePoll = message
          case store.expire(polls, room, generation) {
            Ok(state) -> {
              let #(event, payload) = encode_event(PollClosed(state))
              channel.next(room, [
                channel.broadcast(event, payload),
              ])
            }
            Error(Nil) -> channel.stay(room)
          }
        })
        |> channel.on_terminate(fn(room, _reason) {
          store.leave(polls, room)
          []
        })
      }
    }
  })
}

fn handle_command(
  polls: store.Store,
  room: String,
  command: poll.Command,
  reply: Option(ReplyReference),
) -> channel.Next(String) {
  case command {
    poll.GetState ->
      channel.next(room, [
        channel.reply_ok(reply, poll.to_json(store.get(polls, room))),
      ])
    poll.Vote(choice) ->
      case store.vote(polls, room, choice) {
        Ok(state) -> {
          let #(event, payload) = encode_event(StateChanged(state))
          channel.next(room, [
            channel.reply_ok(reply, poll.to_json(state)),
            channel.broadcast_from(event, payload),
          ])
        }
        Error(error) ->
          channel.next(room, [
            channel.reply_error(reply, poll.error_to_json(error)),
          ])
      }
    poll.Close -> {
      let actions = case store.close(polls, room) {
        store.ClosedNow(state) -> {
          let #(event, payload) = encode_event(PollClosed(state))
          [
            channel.reply_ok(reply, poll.to_json(state)),
            channel.broadcast(event, payload),
          ]
        }
        store.AlreadyClosed(state) -> [
          channel.reply_ok(reply, poll.to_json(state)),
        ]
        store.RoomNotFound -> [channel.discard_reply(reply)]
      }
      channel.next(room, actions)
    }
    poll.Unsupported -> channel.next(room, [channel.discard_reply(reply)])
  }
}

fn handle_invalid_message(
  room: String,
  error: poll.CommandError,
  reply: Option(ReplyReference),
) -> channel.Next(String) {
  // Keep the tutorial's policy: ignore unsupported input, with or without a ref.
  case error {
    poll.UnknownEvent(_) | poll.InvalidChoice ->
      channel.next(room, [channel.discard_reply(reply)])
  }
}

fn guide_channel() -> channel.Handler {
  channel.handler("guide", fn(context) {
    timer_message(context.self)
    channel.accept(0)
    |> channel.on_info(fn(count, message) {
      let Ready(text) = message
      let #(event, payload) = encode_event(GuideTip(text, count + 1))
      channel.next(count + 1, [
        channel.push(event, payload),
      ])
    })
  })
}

fn timer_message(sender: channel.Sender(GuideInfo)) -> Nil {
  case
    channel.notify(
      sender,
      Ready("A second handler owns this private message type."),
    )
  {
    Ok(Nil) -> Nil
    Error(error) ->
      io.println_error(
        "[live_poll] guide notification rejected: " <> overload.describe(error),
      )
  }
}
