import beryl
import beryl/channel
import beryl/transport/server
import beryl/wire
import beryl_mist as mist_transport
import collab_document/app as document_app
import collab_document/auth
import collab_document/document_store
import collab_document/router
import example_helper/static
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import mist

pub fn main() -> Nil {
  let assert Ok(static_directory) = static.priv_static("collab_document")
  let secret = auth.new_secret()
  let assert Ok(store) = document_store.start()

  // Dependencies the document logic needs: the doc store and the shared
  // HMAC secret for join-level tenant token verification.
  let context = document_app.Context(store: store, secret: secret)

  let assert Ok(#(channels, beryl_specification)) =
    channel.child_spec(beryl.config(wire.phoenix_codec()), handlers: [
      document_app.handler(context),
    ])
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(beryl_specification)
    |> static_supervisor.start()

  io.println("📝 Collaborative CRDT Docs Demo")
  io.println("   Open http://localhost:8002")
  io.println("")

  let context_router =
    router.Context(channels:, store:, secret:, base_path: "", static_directory:)

  let assert Ok(_) =
    fn(http_request) {
      mist_transport.upgrade(
        http_request,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(http_request, context_router) },
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}
