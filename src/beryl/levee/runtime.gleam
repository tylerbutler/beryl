//// Runtime - Gleam-side bridge for Elixir WebSocket handler
////
//// Provides functions that Elixir can call to interact with the beryl
//// coordinator without needing to know Gleam's internal type representations.

import beryl
import beryl/coordinator
import beryl/levee/document_channel
import gleam/dynamic.{type Dynamic}
import gleam/erlang/process

/// Start the beryl channels system and register the document channel handler.
///
/// Called once from Elixir at application startup (Levee.Channels GenServer).
/// Returns {:ok, Channels} or {:error, reason}.
pub fn start() -> Result(beryl.Channels, beryl.StartError) {
  case beryl.start(beryl.default_config()) {
    Error(e) -> Error(e)
    Ok(channels) -> {
      let handler = document_channel.new()
      // Register directly with coordinator since handler is already type-erased
      let _ =
        process.call(channels.coordinator, 5000, fn(reply) {
          coordinator.RegisterChannel("document:*", handler, reply)
        })
      Ok(channels)
    }
  }
}

/// Notify coordinator that a new WebSocket connection was established.
///
/// Called from Elixir SocketHandler.init/1.
pub fn notify_connected(
  channels: beryl.Channels,
  socket_id: String,
  send_fn: fn(String) -> Result(Nil, Nil),
  handler_pid: Dynamic,
) -> Nil {
  process.send(
    channels.coordinator,
    coordinator.SocketConnected(
      socket_id,
      send_fn,
      fn(_) { Ok(Nil) },
      handler_pid,
    ),
  )
}

/// Notify coordinator that a WebSocket connection was closed.
///
/// Called from Elixir SocketHandler.terminate/2.
pub fn notify_disconnected(channels: beryl.Channels, socket_id: String) -> Nil {
  process.send(channels.coordinator, coordinator.SocketDisconnected(socket_id))
}

/// Handle a raw wire protocol message from a WebSocket client.
///
/// Decodes the JSON text and routes it to the coordinator as the
/// appropriate message type. Called from Elixir SocketHandler.handle_in/2.
pub fn handle_raw_message(
  channels: beryl.Channels,
  socket_id: String,
  raw_text: String,
) -> Nil {
  coordinator.route_message(channels.coordinator, socket_id, raw_text)
}

/// Get the coordinator subject from a Channels struct.
///
/// Provided for advanced use cases where Elixir needs direct access.
pub fn get_coordinator(
  channels: beryl.Channels,
) -> process.Subject(coordinator.Message) {
  channels.coordinator
}
