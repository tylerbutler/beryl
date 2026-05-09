import beryl
import beryl/transport/mist as mist_transport
import collab_docs/channel
import collab_docs/doc_store
import collab_docs/router
import gleam/erlang/process
import gleam/io
import mist

pub fn main() {
  let assert Ok(store) = doc_store.start()
  let assert Ok(channels) = beryl.start(beryl.default_config())
  let handler = channel.new_handler(channels, store)
  let assert Ok(_) = beryl.register(channels, "document:*:*", handler)

  io.println("📝 Collaborative CRDT Docs Demo")
  io.println("   Open http://localhost:8002")
  io.println("")

  let ctx = router.Context(channels:, store:)

  let assert Ok(_) =
    fn(req) {
      mist_transport.upgrade(
        req,
        channels.coordinator,
        mist_transport.default_config("/socket/websocket"),
        fn() { router.handle_request(req, ctx) },
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}
