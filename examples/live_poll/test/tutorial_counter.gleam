import beryl/socket
import gleam/json
import gleam/option.{None, Some}

pub type CounterMessage {
  Increment
}

/// Start the teaching counter with no output.
pub fn counter_init(
  _info: socket.ConnectInfo(CounterMessage),
) -> #(Int, List(socket.Effect)) {
  #(0, [])
}

/// Separate private model changes from replies to client requests.
pub fn counter_update(
  count: Int,
  input: socket.Input(CounterMessage),
) -> socket.Next(Int) {
  case input {
    socket.Join("counter:demo", _payload, reference) ->
      socket.Next(count, [socket.AcceptJoin(reference, None)])
    socket.Join(_, _, reference) ->
      socket.Next(count, [
        socket.RejectJoin(reference, json.string("unknown topic")),
      ])
    socket.Info(Increment) -> socket.Next(count + 1, [])
    socket.Message("counter:demo", "get_count", _payload, reply) ->
      socket.Next(count, socket.reply_ok(reply, json.int(count)))
    socket.Message(_, _, _, Some(reference)) ->
      socket.Next(count, [socket.DiscardReply(reference)])
    socket.Message(_, _, _, None) | socket.Binary(_, _) | socket.Closed(_, _) ->
      socket.Next(count, [])
  }
}
