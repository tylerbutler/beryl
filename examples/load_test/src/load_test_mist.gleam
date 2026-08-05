import beryl/transport/server
import beryl_mist
import gleam/erlang/process
import gleam/io
import load_test/app
import load_test/mist as http
import mist

pub fn main() {
  let app.App(channels:) = app.start()
  let port = app.port()
  let interface = app.bind_address()
  let assert Ok(_) =
    fn(request) {
      beryl_mist.upgrade(
        request,
        channels,
        server.default_config("/socket"),
        fn() { http.handle(request, channels) },
      )
    }
    |> mist.new
    |> mist.bind(interface)
    |> mist.port(port)
    |> mist.start
  io.println("load_test (Mist) listening on " <> interface)
  process.sleep_forever()
}
