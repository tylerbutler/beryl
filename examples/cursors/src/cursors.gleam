import beryl
import beryl/event.{type Event, type Next}
import beryl/presence
import beryl/wire
import beryl_mist as mist_transport
import cursors/app
import cursors/router
import envoy
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import gleam/result
import mist

/// Socket-wide state: one cursor model per joined `cursor:*` topic.
type Model {
  Model(socket_id: String, cursors: Dict(String, app.Model))
}

pub fn main() {
  // Start presence tracking
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  let ctx = app.Ctx(presence: presence_actor)

  // Rate limiting for cursor events
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_presence_handle(presence_actor)

  let assert Ok(channels) =
    beryl.start_app(
      config,
      init: fn(info: event.ConnectInfo(Nil)) {
        #(Model(socket_id: info.socket_id, cursors: dict.new()), [])
      },
      update: fn(model, ev) { update(ctx, model, ev) },
    )

  // Honor $PORT (Railway/PaaS) and $HOST/$BIND_ADDRESS; fall back to local defaults.
  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  io.println("🖱️  Collaborative Cursors Demo")
  io.println("   Listening on " <> interface <> ":" <> int.to_string(port))
  io.println("")

  // Start the HTTP server
  let router_ctx =
    router.Context(channels:, presence: presence_actor, base_path: "")

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, router_ctx) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

/// Route events for `cursor:*` topics to the cursors app, threading its
/// model through the per-topic `Dict`.
fn update(ctx: app.Ctx, model: Model, ev: Event(Nil)) -> Next(Model, Nil) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "cursor:" <> _ -> {
          let #(joined, effects) =
            app.join(ctx, model.socket_id, topic, payload, ref)
          event.Next(store(model, topic, joined), effects)
        }
        _ ->
          event.Next(model, [
            event.RejectJoin(
              ref,
              json.object([#("reason", json.string("unknown_topic"))]),
            ),
          ])
      }

    event.Message(topic, event_name, payload, _ref) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            app.update(ctx, model.socket_id, topic, sub, event_name, payload)
          event.Next(store(model, topic, Some(sub)), effects)
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.cursors, topic) {
        Ok(sub) ->
          event.Next(
            Model(..model, cursors: dict.delete(model.cursors, topic)),
            app.closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    event.Binary(_, _) | event.Info(_) -> event.Next(model, [])
  }
}

fn store(model: Model, topic: String, sub: option.Option(app.Model)) -> Model {
  case sub {
    Some(sub) -> Model(..model, cursors: dict.insert(model.cursors, topic, sub))
    None -> model
  }
}
