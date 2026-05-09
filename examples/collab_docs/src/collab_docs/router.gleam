import beryl
import collab_docs/doc_store.{type Store}
import gleam/bytes_tree
import gleam/erlang/application
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import gleam/uri
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(channels: beryl.Channels, store: Store)
}

pub fn handle_request(
  req: Request(Connection),
  _ctx: Context,
) -> Response(ResponseData) {
  use <- serve_static(req, under: "/static", from: priv_directory())

  case request.path_segments(req) {
    [] -> index_page()
    _ -> not_found()
  }
}

fn index_page() -> Response(ResponseData) {
  let html =
    "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Collaborative CRDT Docs — beryl demo</title>
  <link rel=\"stylesheet\" href=\"/static/style.css\">
</head>
<body>
  <main id=\"app\">
    <header>
      <h1>Collaborative CRDT Docs</h1>
      <p>Type-safe realtime document state powered by beryl.</p>
    </header>
    <section id=\"toolbar\">
      <button id=\"add-todo\" type=\"button\">Add todo</button>
      <button id=\"add-note\" type=\"button\">Add note</button>
      <span id=\"status\">Connecting…</span>
    </section>
    <section id=\"blocks\" aria-live=\"polite\"></section>
  </main>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\"></script>
  <script type=\"module\" src=\"/static/app.js\"></script>
</body>
</html>"

  html_response(html)
}

fn serve_static(
  req: Request(Connection),
  under prefix: String,
  from directory: String,
  next handler: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  let path = drop_leading_slashes(req.path)
  let prefix = drop_leading_slashes(prefix)

  case req.method, string.starts_with(path, prefix) {
    http.Get, True -> {
      let static_path = path |> string.drop_start(string.length(prefix))
      let relative =
        static_path
        |> uri.percent_decode
        |> result.unwrap(static_path)
        |> string.split("/")
        |> list.filter(fn(segment) {
          segment != "" && segment != "." && segment != ".."
        })
        |> string.join("/")

      case relative {
        "" -> not_found()
        _ -> {
          let file_path = directory <> "/" <> relative
          case mist.send_file(file_path, offset: 0, limit: option.None) {
            Ok(body) ->
              response.new(200)
              |> response.set_header("content-type", mime_type_for(file_path))
              |> response.set_body(body)
            Error(mist.UnknownFileError) ->
              response.new(500)
              |> response.set_body(mist.Bytes(bytes_tree.new()))
            Error(_) -> not_found()
          }
        }
      }
    }
    _, _ -> handler()
  }
}

fn html_response(html: String) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

fn not_found() -> Response(ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
}

fn drop_leading_slashes(path: String) -> String {
  case path {
    "/" <> rest -> drop_leading_slashes(rest)
    _ -> path
  }
}

fn mime_type_for(path: String) -> String {
  case string.split(path, ".") |> list.last {
    Ok("css") -> "text/css; charset=utf-8"
    Ok("js") -> "application/javascript; charset=utf-8"
    Ok("mjs") -> "application/javascript; charset=utf-8"
    Ok("html") -> "text/html; charset=utf-8"
    Ok("json") -> "application/json; charset=utf-8"
    _ -> "application/octet-stream"
  }
}

fn priv_directory() -> String {
  let assert Ok(priv) = application.priv_directory("collab_docs")
  priv <> "/static"
}
