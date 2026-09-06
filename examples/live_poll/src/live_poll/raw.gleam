import beryl/socket
import gleam/dynamic.{type Dynamic}
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/set.{type Set}
import gleam/string
import live_poll/poll
import live_poll/store
import live_poll/timer

pub type Stage {
  ReadOnly
  Voting
  Timed
}

pub type Message {
  ClosePoll(topic: String)
}

pub type Model {
  Model(sender: socket.Sender(Message), topics: Set(String))
}

pub fn init(
  info: socket.ConnectInfo(Message),
) -> #(Model, List(socket.Effect)) {
  #(Model(sender: info.self, topics: set.new()), [])
}

pub fn update(
  stage: Stage,
  polls: store.Store,
  clock: timer.Timer,
  duration_ms: Int,
) -> fn(Model, socket.Input(Message)) -> socket.Next(Model) {
  fn(model: Model, input: socket.Input(Message)) {
    case input {
      socket.Join(topic, _payload, ref) -> {
        case room_name(topic) {
          Ok(room) -> {
            store.join(polls, room)
            case stage {
              Timed ->
                timer.after(clock, duration_ms, fn() {
                  socket.notify(model.sender, ClosePoll(topic))
                })
              ReadOnly | Voting -> Nil
            }
            socket.Next(
              Model(..model, topics: set.insert(model.topics, topic)),
              [socket.AcceptJoin(ref, None)],
            )
          }
          Error(_) ->
            socket.Next(model, [
              socket.RejectJoin(
                ref,
                json.object([#("reason", json.string("unknown_topic"))]),
              ),
            ])
        }
      }
      socket.Message(topic, event, payload, reply) ->
        case set.contains(model.topics, topic), room_name(topic) {
          True, Ok(room) ->
            handle_command(
              stage,
              polls,
              model,
              topic,
              room,
              event,
              payload,
              reply,
            )
          False, Ok(_) | False, Error(_) | True, Error(_) ->
            socket.Next(model, [])
        }
      socket.Info(ClosePoll(topic)) ->
        case room_name(topic) {
          Ok(room) -> {
            let effects = case store.close(polls, room) {
              store.ClosedNow(state) -> [
                socket.Broadcast(topic, "poll_closed", poll.to_json(state)),
              ]
              store.AlreadyClosed(_) | store.RoomNotFound -> []
            }
            socket.Next(model, effects)
          }
          Error(_) -> socket.Next(model, [])
        }
      socket.Closed(topic, _reason) -> {
        case room_name(topic) {
          Ok(room) -> store.leave(polls, room)
          Error(_) -> Nil
        }
        socket.Next(Model(..model, topics: set.delete(model.topics, topic)), [])
      }
      socket.Binary(_, _) -> socket.Next(model, [])
    }
  }
}

fn handle_command(
  stage: Stage,
  polls: store.Store,
  model: Model,
  topic: String,
  room: String,
  event: String,
  payload: Dynamic,
  reply: Option(socket.ReplyRef),
) -> socket.Next(Model) {
  case poll.command(event, payload) {
    poll.GetState ->
      socket.Next(
        model,
        socket.reply_ok(reply, poll.to_json(store.get(polls, room))),
      )
    poll.Vote(choice) ->
      case stage {
        ReadOnly -> socket.Next(model, [])
        Voting | Timed ->
          case store.vote(polls, room, choice) {
            Ok(state) ->
              socket.Next(
                model,
                socket.reply_ok(reply, poll.to_json(state))
                  |> list.append([
                    socket.BroadcastFrom(
                      topic,
                      "poll_state",
                      poll.to_json(state),
                    ),
                  ]),
              )
            Error(error) ->
              socket.Next(model, reply_error(reply, poll.error_to_json(error)))
          }
      }
    poll.Close ->
      case stage {
        Timed -> {
          case store.close(polls, room) {
            store.ClosedNow(state) ->
              socket.Next(
                model,
                list.append(socket.reply_ok(reply, poll.to_json(state)), [
                  socket.Broadcast(topic, "poll_closed", poll.to_json(state)),
                ]),
              )
            store.AlreadyClosed(state) ->
              socket.Next(model, socket.reply_ok(reply, poll.to_json(state)))
            store.RoomNotFound -> socket.Next(model, [])
          }
        }
        ReadOnly | Voting -> socket.Next(model, [])
      }
    poll.Unsupported -> socket.Next(model, [])
  }
}

fn room_name(topic: String) -> Result(String, Nil) {
  case string.split(topic, ":") {
    ["poll", room] if room != "" -> Ok(room)
    _ -> Error(Nil)
  }
}

fn reply_error(
  reply: Option(socket.ReplyRef),
  payload: json.Json,
) -> List(socket.Effect) {
  case reply {
    Some(ref) -> [socket.ReplyError(ref, payload)]
    None -> []
  }
}
