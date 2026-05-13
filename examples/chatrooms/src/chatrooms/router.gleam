import beryl
import beryl/group
import beryl/presence
import gleam/bytes_tree
import gleam/erlang/application
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/option
import gleam/result
import gleam/set
import gleam/string
import gleam/uri
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(
    channels: beryl.Channels,
    presence: presence.Presence,
    groups: group.Groups,
  )
}

pub fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  use <- serve_static(req, under: "/static", from: priv_directory())

  case request.path_segments(req) {
    [] -> index_page(ctx)
    ["api", "rooms"] -> rooms_api(ctx)
    _ -> not_found()
  }
}

fn rooms_api(ctx: Context) -> Response(ResponseData) {
  let rooms = case group.topics(ctx.groups, "public") {
    Ok(topics) ->
      topics
      |> set.to_list
      |> list.map(fn(topic) {
        let room_name = case string.split(topic, ":") {
          [_, name] -> name
          _ -> topic
        }
        let user_count = list.length(presence.list(ctx.presence, topic))
        json.object([
          #("topic", json.string(topic)),
          #("name", json.string(room_name)),
          #("users", json.int(user_count)),
        ])
      })
    Error(_) -> []
  }

  let body = json.to_string(json.array(rooms, fn(r) { r }))
  json_response(body)
}

fn index_page(ctx: Context) -> Response(ResponseData) {
  // Build room list for initial render
  let rooms = case group.topics(ctx.groups, "public") {
    Ok(topics) ->
      topics
      |> set.to_list
      |> list.sort(string.compare)
      |> list.map(fn(topic) {
        case string.split(topic, ":") {
          [_, name] -> name
          _ -> topic
        }
      })
    Error(_) -> []
  }
  let room_options =
    rooms
    |> list.map(fn(name) {
      "<li class=\"room-item\" data-room=\""
      <> name
      <> "\"><span class=\"room-hash\">#</span> "
      <> name
      <> "</li>"
    })
    |> string.join("")

  let html = "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Chat Rooms — beryl demo</title>
  <link rel=\"stylesheet\" href=\"/static/style.css\">
</head>
<body>
  <div id=\"app\">
    <nav id=\"rooms-sidebar\">
      <h2>Rooms</h2>
      <ul id=\"room-list\">" <> room_options <> "</ul>
      <div class=\"sidebar-footer\">
        <p class=\"powered-by\">Powered by <a href=\"https://github.com/tylerbutler/beryl\">beryl</a></p>
      </div>
    </nav>
    <main id=\"chat-area\">
      <header id=\"chat-header\">
        <h1 id=\"room-title\">Select a room</h1>
      </header>
      <div id=\"messages\"></div>
      <div id=\"typing-indicator\"></div>
      <form id=\"msg-form\">
        <input type=\"text\" id=\"msg-input\" placeholder=\"Type a message...\" autocomplete=\"off\" disabled>
        <button type=\"submit\" id=\"send-btn\" disabled>Send</button>
      </form>
    </main>
    <aside id=\"users-sidebar\">
      <h2>Online</h2>
      <ul id=\"user-list\"></ul>
    </aside>
  </div>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\" integrity=\"sha384-9Rsr2KoQMtWNQakugNsDiGsZ/5eQnJHeBhiocJMdHvnyN8ifwcytSTzPpb1xydYk\" crossorigin=\"anonymous\"></script>
  <script src=\"/static/app.js\"></script>
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

fn json_response(json: String) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json)))
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
  let assert Ok(priv) = application.priv_directory("chatrooms")
  priv <> "/static"
}
