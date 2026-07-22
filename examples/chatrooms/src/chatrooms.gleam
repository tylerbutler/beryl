import beryl
import beryl/event.{type Event, type Next}
import beryl/group
import beryl/presence
import beryl/wire
import beryl_mist as mist_transport
import chatrooms/app
import chatrooms/router
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/http/request
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import mist

/// Socket-wide state: one chat model per joined room topic.
type Model {
  Model(socket_id: String, rooms: Dict(String, app.Model))
}

pub fn main() {
  // Start presence tracking
  let presence_config = presence.default_config("node1")
  let assert Ok(presence_actor) = presence.start(presence_config)

  // Start groups and create default room group
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  let ctx = app.Ctx(presence: presence_actor, groups: groups)

  // Rate limiting: socket-wide message/join budgets plus a per-room cap.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 10, burst: 20)
    |> beryl.with_presence_handle(presence_actor)

  let assert Ok(channels) =
    beryl.start_app(
      config,
      init: fn(info: event.ConnectInfo(Nil)) {
        #(Model(socket_id: info.socket_id, rooms: dict.new()), [])
      },
      update: fn(model, ev) { update(ctx, model, ev) },
    )

  io.println("💬 Chat Rooms Demo")
  io.println("   Open http://localhost:8001?token=beryl-demo")
  io.println("")

  // Start the HTTP server
  let router_ctx =
    router.Context(channels:, presence: presence_actor, groups:, base_path: "")
  let ws_config =
    mist_transport.default_config("/socket/websocket")
    |> mist_transport.with_on_connect(fn(req) {
      case get_query_param(req, "token") {
        Ok("beryl-demo") -> Ok(Nil)
        _ -> Error(mist_transport.ConnectRejected)
      }
    })

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(req, channels, ws_config, fn() {
        router.handle_request(req, router_ctx)
      })
    }
    |> mist.new
    |> mist.port(8001)
    |> mist.start

  process.sleep_forever()
}

/// Route events for `room:*` topics to the chat app, threading its model
/// through the per-topic `Dict`.
fn update(ctx: app.Ctx, model: Model, ev: Event(Nil)) -> Next(Model, Nil) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "room:" <> _ -> {
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

    event.Message(topic, event_name, payload, ref) ->
      case dict.get(model.rooms, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            app.update(
              ctx,
              model.socket_id,
              topic,
              sub,
              event_name,
              payload,
              ref,
            )
          event.Next(store(model, topic, Some(sub)), effects)
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.rooms, topic) {
        Ok(sub) ->
          event.Next(
            Model(..model, rooms: dict.delete(model.rooms, topic)),
            app.closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    event.Binary(_, _) | event.Info(_) -> event.Next(model, [])
  }
}

fn store(model: Model, topic: String, sub: option.Option(app.Model)) -> Model {
  case sub {
    Some(sub) -> Model(..model, rooms: dict.insert(model.rooms, topic, sub))
    None -> model
  }
}

fn get_query_param(req, name: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(params) ->
      list.find(params, fn(pair) { pair.0 == name })
      |> result.map(fn(pair) { pair.1 })
    Error(_) -> Error(Nil)
  }
}
