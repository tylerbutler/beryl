import app_test_helper
import beryl
import beryl/presence
import beryl/presence/wire as presence_wire
import beryl/pubsub
import beryl/socket
import beryl/transport
import beryl/transport/server
import beryl/wire
import gleam/erlang/process
import gleam/json
import gleam/list
import gleam/option

const topic = "room:distributed"

pub opaque type Client {
  Client(channels: beryl.Sockets, control: process.Subject(Message))
}

type Message {
  Outbound(server.SendRequest)
  Frames(reply: process.Subject(List(String)))
}

/// Run a real socket runtime and its shared WebSocket transport on this node.
/// The adapter records encoded text frames and acknowledges outbound writes.
pub fn start_client(scope: String) -> Client {
  let ready = process.new_subject()
  let _owner =
    process.spawn_unlinked(fn() {
      let pubsub = pubsub.start(pubsub.config_with_scope(scope))
      let assert Ok(channels) =
        app_test_helper.start_app(
          beryl.config(wire.phoenix_codec()) |> beryl.with_pubsub(pubsub),
          init: app_test_helper.accepting_init,
          update: app_test_helper.accepting_update,
        )
      let control = process.new_subject()
      let assert Ok(permit) =
        transport.acquire_connection_slot(channels, "127.0.0.1")
      let #(connection, outbound) =
        server.init_connection(
          sockets: channels,
          seed: socket.empty_seed(),
          connection_permit: permit,
          base_selector: process.new_selector(),
          config: server.default_config("/socket"),
          force_close: fn() { Ok(Nil) },
          logger_name: "beryl.presence.socket.test",
          telemetry: transport.telemetry(channels, transport.Mist),
          codec: option.None,
        )
      let selector =
        process.map_selector(outbound, Outbound)
        |> process.select(control)
      let assert server.Continue(connection) =
        server.handle_text_frame(
          connection,
          "[\"join\",\"join\",\"room:distributed\",\"phx_join\",{}]",
        )
      process.send(ready, Client(channels, control))
      receive_frames(connection, selector, [])
    })
  let assert Ok(client) = process.receive(ready, 5000)
  client
}

/// Use the documented diff callback, followed by an ordered global marker.
/// The marker proves a remote client has passed this callback's delivery turn.
pub fn start_presence(
  client: Client,
  scope: String,
  replica: String,
) -> #(presence.Presence, process.Pid) {
  let pubsub = pubsub.start(pubsub.config_with_scope(scope))
  let config =
    presence.default_config(replica)
    |> presence.with_pubsub(pubsub)
    |> presence.with_broadcast_interval(30)
    |> presence.with_on_diff(fn(diff) {
      let assert Ok(Nil) =
        beryl.broadcast_presence_diff(client.channels, topic, diff)
      let assert Ok(Nil) =
        beryl.broadcast(
          client.channels,
          topic,
          "presence_diff_barrier",
          json.object([
            #("replica", json.string(replica)),
            #("diff", presence_wire.encode_diff(diff, topic)),
          ]),
        )
      Nil
    })
  let assert Ok(tracker) = presence.start(config)
  let assert Ok(pid) = process.subject_owner(presence.subject(tracker))
  process.unlink(pid)
  #(tracker, pid)
}

/// Read only frames the transport has completed writing.
pub fn frames(client: Client) -> List(String) {
  process.call(client.control, 1000, Frames)
}

fn receive_frames(
  connection: server.ConnectionState,
  selector: process.Selector(Message),
  frames: List(String),
) -> Nil {
  case process.selector_receive_forever(selector) {
    Frames(reply) -> {
      process.send(reply, list.reverse(frames))
      receive_frames(connection, selector, frames)
    }
    Outbound(server.SendText(text, bytes)) -> {
      let assert server.Continue(connection) =
        server.finish_outbound_write(connection, bytes, True)
      receive_frames(connection, selector, [text, ..frames])
    }
    Outbound(server.SendBinary(_, _)) -> panic as "Expected Phoenix text frames"
    Outbound(server.Close) -> server.close_connection(connection)
  }
}
