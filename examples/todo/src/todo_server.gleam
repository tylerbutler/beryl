import beryl
import beryl/overload
import beryl/transport/server
import beryl/wire
import beryl_mist
import example_helper/static
import gleam/erlang/process
import gleam/io
import gleam/otp/static_supervisor
import mist
import todo_server/app
import todo_server/router
import todo_server/store

pub fn main() -> Nil {
  let assert Ok(static_directory) = static.priv_static("todo_server")
  let #(channels, _store) = start_system()

  io.println("✓ Realtime Todo")
  io.println("  Open http://localhost:8011")

  let assert Ok(_) =
    fn(request) {
      beryl_mist.upgrade(
        request,
        channels,
        server.default_config("/socket/websocket"),
        fn() { router.handle_request(request, static_directory) },
      )
    }
    |> mist.new
    |> mist.port(8011)
    |> mist.start

  process.sleep_forever()
}

/// Start the shared list and its dependent socket runtime.
pub fn start_system() -> #(beryl.Sockets, store.Store) {
  let store = store.new()
  let assert Ok(#(channels, beryl_spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: app.init,
      update: app.update(store),
    )
  let assert Ok(_root) =
    static_supervisor.new(static_supervisor.RestForOne)
    |> static_supervisor.add(
      store.child_spec(store, fn(event, payload) {
        case beryl.broadcast(channels, "todos", event, payload) {
          Ok(Nil) -> Ok(Nil)
          Error(error) -> {
            io.println_error(overload.describe(error))
            Error(Nil)
          }
        }
      }),
    )
    |> static_supervisor.add(beryl_spec)
    |> static_supervisor.start()

  #(channels, store)
}
