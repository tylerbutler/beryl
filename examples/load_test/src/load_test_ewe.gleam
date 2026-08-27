import beryl/transport/server
import beryl_ewe
import ewe
import gleam/erlang/process
import gleam/io
import load_test/app
import load_test/ewe as http

pub fn main() {
  let app.App(channels:) = app.start()
  let interface = app.bind_address()
  let assert Ok(_) =
    beryl_ewe.handler(channels, server.default_config("/socket"), fn(request) {
      http.handle(request, channels)
    })
    |> ewe.new
    |> ewe.listening(port: app.port())
    |> ewe.bind(interface:)
    |> ewe.start
  io.println("load_test (Ewe) listening on " <> interface)
  process.sleep_forever()
}
