import beryl
import beryl/wire
import beryl_mist as mist_transport
import collab_docs/auth
import collab_docs/channel
import collab_docs/doc_store
import collab_docs/router
import gleam/erlang/process
import gleam/io
import mist

pub fn main() {
  let secret = auth.new_secret()
  let assert Ok(store) = doc_store.start()
  let assert Ok(channels) = beryl.start(beryl.config(wire.phoenix_codec()))
  let handler = channel.new_handler(channels, store, secret)
  let assert Ok(_) = beryl.register(channels, "document:*:*", handler)

  io.println("📝 Collaborative CRDT Docs Demo")
  io.println("   Open http://localhost:8002")
  io.println("")

  let ctx = router.Context(channels:, store:, secret:, base_path: "")

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx) },
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}
