//// Showcase: all three real-time examples on one socket, composed through
//// app-side dispatch.
////
//// This demonstrates composition with the `beryl.child_spec` API: the cursors,
//// chatrooms, and collab_docs packages each export an embeddable
//// `Model`/`join`/`update`/`closed` triple (`<example>/app`), and this app
//// owns the socket-wide model and router — one `Dict` of sub-models per
//// topic namespace, routed by topic prefix, pruned on `Closed`.

import beryl
import beryl/group
import beryl/socket.{type Input, type Next}
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import chatrooms/app as chat_app
import chatrooms/router as chatrooms_router
import collab_docs/app as docs_app
import collab_docs/auth as docs_auth
import collab_docs/doc_store
import collab_docs/router as collab_docs_router
import cursors/app as cursors_app
import cursors/router as cursors_router
import envoy
import example_helpers/router as topic_router
import example_helpers/session_presence
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/otp/static_supervisor
import gleam/result
import mist
import showcase/router

/// Socket-wide state: one sub-model per joined topic, grouped by the
/// namespace that owns it. `Closed` events prune their entry.
type Model {
  Model(
    socket_id: String,
    cursors: Dict(String, cursors_app.Model),
    rooms: Dict(String, chat_app.Model),
    docs: Dict(String, docs_app.Model),
  )
}

/// Dependencies for the three embedded apps.
type Ctx {
  Ctx(cursors: cursors_app.Ctx, rooms: chat_app.Ctx, docs: docs_app.Ctx)
}

pub fn main() {
  let presence_tracker = session_presence.start()

  // Chatrooms-specific state.
  let assert Ok(groups) = group.start()
  let assert Ok(_) = group.create(groups, "public")
  let assert Ok(_) = group.add(groups, "public", "room:general")
  let assert Ok(_) = group.add(groups, "public", "room:random")
  let assert Ok(_) = group.add(groups, "public", "room:help")

  // collab_docs-specific state.
  let docs_secret = docs_auth.new_secret()
  let assert Ok(docs_store) = doc_store.start()

  let ctx =
    Ctx(
      cursors: cursors_app.Ctx(presence: presence_tracker),
      rooms: chat_app.Ctx(presence: presence_tracker, groups: groups),
      docs: docs_app.Ctx(store: docs_store, secret: docs_secret),
    )

  // Per-topic-pattern rate limits replace the old single global
  // channel-rate compromise: cursors stream fast, chat and docs do not.
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_message_rate(per_second: 30, burst: 60)
    |> beryl.with_join_rate(per_second: 5, burst: 10)
    |> beryl.with_topic_rate(pattern: "cursor:*", per_second: 30, burst: 60)
    |> beryl.with_topic_rate(pattern: "room:*", per_second: 10, burst: 20)
    |> beryl.with_topic_rate(pattern: "document:*:*", per_second: 10, burst: 20)

  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      config,
      init: fn(info: socket.ConnectInfo(Nil)) {
        #(
          Model(
            socket_id: info.socket_id,
            cursors: dict.new(),
            rooms: dict.new(),
            docs: dict.new(),
          ),
          [],
        )
      },
      update: update(ctx),
    )
  session_presence.configure(presence_tracker, channels)
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  // Build per-example contexts pinned to their URL prefix.
  let cursors_ctx = cursors_router.Context(channels:, base_path: "/cursors")
  let chatrooms_ctx =
    chatrooms_router.Context(
      channels:,
      presence: presence_tracker,
      groups:,
      base_path: "/chat",
    )
  let collab_docs_ctx =
    collab_docs_router.Context(
      channels:,
      store: docs_store,
      secret: docs_secret,
      base_path: "/docs",
    )
  let showcase_ctx =
    router.Context(
      cursors: cursors_ctx,
      chatrooms: chatrooms_ctx,
      collab_docs: collab_docs_ctx,
    )

  let port =
    envoy.get("PORT")
    |> result.try(int.parse)
    |> result.unwrap(8000)
  let interface =
    envoy.get("BIND_ADDRESS")
    |> result.unwrap("localhost")

  io.println("✨ beryl examples showcase (app-side dispatch)")
  io.println("   Listening on " <> interface <> ":" <> int.to_string(port))
  io.println("")

  // Single WebSocket endpoint at /socket/websocket. No token gate — this
  // is a public demo. Phoenix JS client (new Socket("/socket")) in every
  // example targets this URL out of the box.
  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(req, showcase_ctx) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start

  process.sleep_forever()
}

/// Build the composed router once. The read-only lobby remains mounted so the
/// chatrooms UI keeps live room-count invalidations in the showcase.
fn update(ctx: Ctx) -> fn(Model, Input(Nil)) -> Next(Model, Nil) {
  let namespaces = [
    topic_router.accept_only("lobby"),
    cursors_app.namespace(
      ctx.cursors,
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.cursors },
      put: fn(model: Model, cursors) { Model(..model, cursors: cursors) },
    ),
    chat_app.namespace(
      ctx.rooms,
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.rooms },
      put: fn(model: Model, rooms) { Model(..model, rooms: rooms) },
    ),
    docs_app.namespace(
      ctx.docs,
      socket_id: fn(model: Model) { model.socket_id },
      get: fn(model: Model) { model.docs },
      put: fn(model: Model, docs) { Model(..model, docs: docs) },
    ),
  ]
  fn(model, input) {
    topic_router.route(namespaces, topic_router.unknown_topic(), model, input)
  }
}
