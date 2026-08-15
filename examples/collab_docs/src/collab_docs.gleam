import beryl
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import collab_docs/app as docs_app
import collab_docs/auth
import collab_docs/doc_store
import collab_docs/router
import example_helpers/router as topic_router
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import mist

pub fn main() {
  let secret = auth.new_secret()
  let assert Ok(store) = doc_store.start()

  // Dependencies the document logic needs: the doc store and the shared
  // HMAC secret for join-level tenant token verification.
  let ctx = docs_app.Ctx(store: store, secret: secret)

  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: topic_router.standalone_init,
      update: docs_app.standalone_update(ctx),
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  io.println("📝 Collaborative CRDT Docs Demo")
  io.println("   Open http://localhost:8002")
  io.println("")

  let ctx_router = router.Context(channels:, store:, secret:, base_path: "")

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx_router) },
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}
