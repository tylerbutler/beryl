import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/response
import gleam/io
import mist

/// Minimal placeholder entry point for the collaborative docs example scaffold.
/// Later tasks replace this with the real HTTP/WebSocket server.
pub fn main() {
  io.println(
    "collab_docs example scaffold: server behavior not implemented yet",
  )

  let assert Ok(_) =
    fn(_req) {
      response.new(200)
      |> response.set_header("content-type", "text/html; charset=utf-8")
      |> response.set_body(
        mist.Bytes(bytes_tree.from_string(placeholder_html())),
      )
    }
    |> mist.new
    |> mist.port(8002)
    |> mist.start

  process.sleep_forever()
}

fn placeholder_html() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head><meta charset=\"utf-8\"><title>Collab Docs scaffold</title></head>
<body><h1>Collab Docs scaffold</h1><p>Real example behavior is added in later tasks.</p></body>
</html>"
}
