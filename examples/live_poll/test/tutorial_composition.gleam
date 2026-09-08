//// Checked, untimed teaching extension for chapter 4. The runnable
//// checkpoints keep their original raw and channel handlers.

import beryl/channel
import beryl/socket
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import live_poll/poll
import live_poll/store

pub const initial_tip = "A second handler owns this private message type."

pub type Message {
  ClosePollTopic(topic: String)
  GuideReady(generation: Int, text: String)
}

pub type Model {
  Model(
    sender: socket.Sender(Message),
    topics: Set(String),
    guide_deliveries: Int,
    guide_generation: Int,
  )
}

pub type PollInfo {
  ClosePoll
}

pub type GuideInfo {
  Ready(String)
}

/// Create private state for one raw socket.
pub fn init(
  info: socket.ConnectInfo(Message),
) -> #(Model, List(socket.Effect)) {
  #(Model(info.self, set.new(), 0, 0), [])
}

/// Route poll and guide events in the application-owned socket model.
pub fn update(
  polls: store.Store,
  model: Model,
  input: socket.Input(Message),
) -> socket.Next(Model) {
  case input {
    socket.Join("guide", _, ref) -> {
      let generation = model.guide_generation + 1
      socket.notify(model.sender, GuideReady(generation, initial_tip))
      socket.Next(
        Model(
          ..model,
          topics: set.insert(model.topics, "guide"),
          guide_deliveries: 0,
          guide_generation: generation,
        ),
        [socket.AcceptJoin(ref, None)],
      )
    }
    socket.Join(topic, _, ref) ->
      case room_name(topic) {
        Ok(room) -> {
          store.join(polls, room)
          socket.Next(Model(..model, topics: set.insert(model.topics, topic)), [
            socket.AcceptJoin(ref, None),
          ])
        }
        Error(_) ->
          socket.Next(model, [
            socket.RejectJoin(ref, json.string("unknown topic")),
          ])
      }
    socket.Message(topic, event, payload, reply) ->
      case set.contains(model.topics, topic), room_name(topic) {
        True, Ok(room) ->
          socket.Next(
            model,
            raw_command(polls, room, topic, event, payload, reply),
          )
        False, _ | True, Error(_) -> socket.Next(model, [])
      }
    socket.Info(GuideReady(generation, text)) ->
      case
        set.contains(model.topics, "guide"),
        generation == model.guide_generation
      {
        True, True -> {
          let count = model.guide_deliveries + 1
          socket.Next(Model(..model, guide_deliveries: count), [
            socket.Push("guide", "tip", tip(text, count)),
          ])
        }
        False, _ | True, False -> socket.Next(model, [])
      }
    socket.Info(ClosePollTopic(topic)) ->
      case set.contains(model.topics, topic), room_name(topic) {
        True, Ok(room) ->
          case store.close(polls, room) {
            store.ClosedNow(state) ->
              socket.Next(model, [
                socket.Broadcast(topic, "poll_closed", poll.to_json(state)),
              ])
            store.AlreadyClosed(_) | store.RoomNotFound ->
              socket.Next(model, [])
          }
        False, _ | True, Error(_) -> socket.Next(model, [])
      }
    socket.Closed("guide", _) ->
      socket.Next(
        Model(
          ..model,
          topics: set.delete(model.topics, "guide"),
          guide_deliveries: 0,
        ),
        [],
      )
    socket.Closed(topic, _) -> {
      case room_name(topic) {
        Ok(room) -> store.leave(polls, room)
        Error(_) -> Nil
      }
      socket.Next(Model(..model, topics: set.delete(model.topics, topic)), [])
    }
    socket.Binary(_, _) -> socket.Next(model, [])
  }
}

fn raw_command(
  polls: store.Store,
  room: String,
  topic: String,
  event: String,
  payload: Dynamic,
  reply: Option(socket.ReplyRef),
) -> List(socket.Effect) {
  case poll.command(event, payload) {
    poll.GetState ->
      socket.reply_ok(reply, poll.to_json(store.get(polls, room)))
    poll.Vote(choice) ->
      case store.vote(polls, room, choice) {
        Ok(state) ->
          socket.reply_ok(reply, poll.to_json(state))
          |> list.append([
            socket.BroadcastFrom(topic, "poll_state", poll.to_json(state)),
          ])
        Error(error) ->
          case reply {
            Some(ref) -> [socket.ReplyError(ref, poll.error_to_json(error))]
            None -> []
          }
      }
    poll.Close | poll.Unsupported -> []
  }
}

/// Register two typed handlers; expose the guide sender to the test's actor.
pub fn handlers(
  polls: store.Store,
  guide_sender: fn(channel.Sender(GuideInfo)) -> Nil,
) -> List(channel.Handler) {
  [
    channel.handler("poll:*", fn(context) {
      case room_name(context.topic) {
        Error(_) -> channel.reject(json.string("unknown topic"))
        Ok(room) -> {
          store.join(polls, room)
          channel.accept(room)
          |> channel.on_message(fn(room, message) {
            channel.next(room, channel_command(polls, room, message))
          })
          |> channel.on_info(fn(room, message: PollInfo) {
            let ClosePoll = message
            case store.close(polls, room) {
              store.ClosedNow(state) ->
                channel.next(room, [
                  channel.broadcast("poll_closed", poll.to_json(state)),
                ])
              store.AlreadyClosed(_) | store.RoomNotFound -> channel.stay(room)
            }
          })
          |> channel.on_terminate(fn(room, _) {
            store.leave(polls, room)
            []
          })
        }
      }
    }),
    channel.handler("guide", fn(context) {
      guide_sender(context.self)
      channel.notify(context.self, Ready(initial_tip))
      channel.accept(0)
      |> channel.on_info(fn(count, message) {
        let Ready(text) = message
        channel.next(count + 1, [channel.push("tip", tip(text, count + 1))])
      })
    }),
  ]
}

fn channel_command(
  polls: store.Store,
  room: String,
  message: channel.Message,
) -> List(channel.Action(channel.Active)) {
  case poll.command(message.event, message.payload) {
    poll.GetState -> [
      channel.reply_ok(message.reply, poll.to_json(store.get(polls, room))),
    ]
    poll.Vote(choice) ->
      case store.vote(polls, room, choice) {
        Ok(state) -> [
          channel.reply_ok(message.reply, poll.to_json(state)),
          channel.broadcast_from("poll_state", poll.to_json(state)),
        ]
        Error(error) -> [
          channel.reply_error(message.reply, poll.error_to_json(error)),
        ]
      }
    poll.Close | poll.Unsupported -> []
  }
}

fn room_name(topic: String) -> Result(String, Nil) {
  case string.split(topic, ":") {
    ["poll", room] if room != "" -> Ok(room)
    _ -> Error(Nil)
  }
}

fn tip(text: String, count: Int) -> json.Json {
  json.object([
    #("text", json.string(text)),
    #("delivery", json.int(count)),
  ])
}
