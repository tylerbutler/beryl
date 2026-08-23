import beryl/channel
import gleam/json
import live_poll/poll
import live_poll/store
import live_poll/timer

pub type PollInfo {
  ClosePoll
}

type GuideInfo {
  Ready(String)
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
    let room = case context.params {
      [room] -> room
      _ -> ""
    }
    store.join(polls, room)
    timer.after(clock, duration_ms, fn() {
      channel.notify(context.self, ClosePoll)
    })

    channel.accept(
      room,
      channel.callbacks()
        |> channel.on_message(fn(room, message) {
          handle_message(polls, room, message)
        })
        |> channel.on_info(fn(room, message) {
          let ClosePoll = message
          case store.close(polls, room) {
            store.ClosedNow(state) ->
              channel.next(room, [
                channel.broadcast("poll_closed", poll.json(state)),
              ])
            store.AlreadyClosed(_) | store.RoomNotFound ->
              channel.next(room, [])
          }
        })
        |> channel.on_terminate(fn(room, _reason) {
          store.leave(polls, room)
          []
        }),
    )
  })
}

fn handle_message(
  polls: store.Store,
  room: String,
  message: channel.Message,
) -> channel.Next(String) {
  case poll.command(message.event, message.payload) {
    poll.GetState ->
      channel.next(room, [
        channel.reply_ok(message.reply, poll.json(store.get(polls, room))),
      ])
    poll.Vote(choice) ->
      case store.vote(polls, room, choice) {
        Ok(state) ->
          channel.next(room, [
            channel.reply_ok(message.reply, poll.json(state)),
            channel.broadcast_from("poll_state", poll.json(state)),
          ])
        Error(error) ->
          channel.next(room, [
            channel.reply_error(message.reply, poll.error_json(error)),
          ])
      }
    poll.Close -> {
      let actions = case store.close(polls, room) {
        store.ClosedNow(state) -> [
          channel.reply_ok(message.reply, poll.json(state)),
          channel.broadcast("poll_closed", poll.json(state)),
        ]
        store.AlreadyClosed(state) -> [
          channel.reply_ok(message.reply, poll.json(state)),
        ]
        store.RoomNotFound -> []
      }
      channel.next(room, actions)
    }
    poll.Unsupported -> channel.next(room, [])
  }
}

fn guide_channel() -> channel.Handler {
  channel.handler("guide", fn(context) {
    timer_message(context.self)
    channel.accept(
      0,
      channel.callbacks()
        |> channel.on_info(fn(count, message) {
          let Ready(text) = message
          channel.next(count + 1, [
            channel.push(
              "tip",
              json.object([
                #("text", json.string(text)),
                #("delivery", json.int(count + 1)),
              ]),
            ),
          ])
        }),
    )
  })
}

fn timer_message(sender: channel.Sender(GuideInfo)) -> Nil {
  channel.notify(
    sender,
    Ready("A second handler owns this private message type."),
  )
}
