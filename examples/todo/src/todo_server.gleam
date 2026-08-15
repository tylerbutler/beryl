import beryl
import beryl/transport/server
import beryl/wire
import beryl_mist
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import mist
import todo_server/app
import todo_server/router
import todo_server/store

pub fn main() {
  let #(store, store_spec) = store.child_spec()
  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: app.init,
      update: app.update(store),
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(store_spec)
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  io.println("✓ Realtime Todo")
  io.println("  Open http://localhost:8011")

  let assert Ok(_) =
    beryl_mist.handler(
      channels,
      server.default_config("/socket/websocket"),
      router.handle_request,
    )
    |> mist.new
    |> mist.port(8011)
    |> mist.start

  process.sleep_forever()
}
