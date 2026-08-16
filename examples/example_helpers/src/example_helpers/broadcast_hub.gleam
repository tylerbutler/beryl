//// A late-bound handle to the running socket system.
////
//// A `beryl/channel` handler acts on its **own** topic: its actions are
//// scoped to the topic it is joined to, at join time, on every message,
//// and again as it terminates. One showcase announcement falls outside
//// that scope — the chat channel publishes room membership changes on the
//// application-wide read-only `lobby` channel.
////
//// Phoenix does this with the endpoint (`MyAppWeb.Endpoint.broadcast/3`);
//// beryl does it with `beryl.broadcast` on the `Sockets` handle. That
//// handle only exists *after* the system is started, and the handler table
//// has to be built *before* it — so this tiny actor holds the handle and
//// is bound once, immediately after startup. Channels send it fire-and-forget
//// publish messages, which keeps them from blocking the socket runtime that
//// is calling them.

import beryl
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result

/// A handle to the application's broadcast hub.
pub opaque type Hub {
  Hub(subject: Subject(Message))
}

type Message {
  Bind(sockets: beryl.Sockets)
  Publish(topic: String, event: String, payload: Json)
}

type State {
  State(sockets: Option(beryl.Sockets))
}

/// Start the hub. It carries no handle until [`bind`](#bind) is called.
pub fn start() -> Result(Hub, actor.StartError) {
  actor.new(State(sockets: None))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Hub(subject: started.data) })
}

/// Give the hub the socket system it should broadcast through. Called once,
/// right after the system starts and before the HTTP listener accepts a
/// connection.
pub fn bind(hub: Hub, sockets: beryl.Sockets) -> Nil {
  process.send(hub.subject, Bind(sockets))
}

/// Broadcast to every subscriber of `topic`, from outside that topic's own
/// channel.
///
/// Fire-and-forget: it returns as soon as the message is enqueued, so a
/// channel callback never blocks the socket runtime on the hub.
pub fn publish(hub: Hub, topic: String, event: String, payload: Json) -> Nil {
  process.send(hub.subject, Publish(topic:, event:, payload:))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message, state.sockets {
    Bind(sockets), _ -> actor.continue(State(sockets: Some(sockets)))

    Publish(topic, event, payload), Some(sockets) -> {
      beryl.broadcast(sockets, topic, event, payload)
      actor.continue(state)
    }

    Publish(topic, event, _payload), None -> {
      // Only reachable if a channel ran before `bind`, which startup order
      // rules out — surface it rather than dropping it silently.
      io.println_error(
        "[broadcast_hub] dropped "
        <> event
        <> " for "
        <> topic
        <> ": hub is not bound to a socket system",
      )
      actor.continue(state)
    }
  }
}
