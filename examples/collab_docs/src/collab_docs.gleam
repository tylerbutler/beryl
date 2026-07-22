import beryl
import beryl/event.{type Event, type Next}
import beryl/wire
import beryl_mist as mist_transport
import collab_docs/app
import collab_docs/auth
import collab_docs/doc_store
import collab_docs/router
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/option.{None, Some}
import mist

/// Socket-wide state: one document model per joined `document:*:*` topic.
type Model {
  Model(socket_id: String, docs: Dict(String, app.Model))
}

pub fn main() {
  let secret = auth.new_secret()
  let assert Ok(store) = doc_store.start()

  let ctx = app.Ctx(store:, secret:)

  let assert Ok(channels) =
    beryl.start_app(
      beryl.config(wire.phoenix_codec()),
      init: fn(info: event.ConnectInfo(Nil)) {
        #(Model(socket_id: info.socket_id, docs: dict.new()), [])
      },
      update: fn(model, ev) { update(ctx, model, ev) },
    )

  io.println("📝 Collaborative CRDT Docs Demo")
  io.println("   Open http://localhost:8002")
  io.println("")

  let router_ctx = router.Context(channels:, store:, secret:, base_path: "")

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
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}

/// Route events for `document:*:*` topics to the docs app, threading its
/// model through the per-topic `Dict`.
fn update(ctx: app.Ctx, model: Model, ev: Event(Nil)) -> Next(Model, Nil) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "document:" <> _ -> {
          let #(joined, effects) =
            app.join(ctx, model.socket_id, topic, payload, ref)
          event.Next(store_doc(model, topic, joined), effects)
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
      case dict.get(model.docs, topic) {
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
          event.Next(store_doc(model, topic, Some(sub)), effects)
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.docs, topic) {
        Ok(sub) ->
          event.Next(
            Model(..model, docs: dict.delete(model.docs, topic)),
            app.closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    event.Binary(_, _) | event.Info(_) -> event.Next(model, [])
  }
}

fn store_doc(
  model: Model,
  topic: String,
  sub: option.Option(app.Model),
) -> Model {
  case sub {
    Some(sub) -> Model(..model, docs: dict.insert(model.docs, topic, sub))
    None -> model
  }
}
