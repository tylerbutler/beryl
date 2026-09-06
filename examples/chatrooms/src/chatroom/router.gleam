import beryl
import beryl/group
import example_helper/session_presence
import example_helper/static
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import gleam/list
import gleam/set
import gleam/string
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(
    channels: beryl.Sockets,
    presence: session_presence.Tracker,
    groups: group.Groups,
    base_path: String,
    static_directory: String,
  )
}

pub fn handle_request(
  http_request: Request(Connection),
  context: Context,
) -> Response(ResponseData) {
  use <- static.serve_static(
    http_request,
    under: context.base_path <> "/static",
    from: context.static_directory,
  )

  case static.match_prefix(http_request, context.base_path) {
    Ok([]) -> index_page(context)
    Ok(["api", "rooms"]) -> rooms_api(context)
    Error(_) | Ok(_) -> static.not_found()
  }
}

fn rooms_api(context: Context) -> Response(ResponseData) {
  let rooms = case group.topics(context.groups, "public") {
    Ok(topics) ->
      topics
      |> set.to_list
      |> list.map(fn(topic) {
        let room_name = case string.split(topic, ":") {
          [_, name] -> name
          _ -> topic
        }
        let user_count = session_presence.count(context.presence, topic)
        json.object([
          #("topic", json.string(topic)),
          #("name", json.string(room_name)),
          #("users", json.int(user_count)),
        ])
      })
    Error(_) -> []
  }

  let body = json.to_string(json.array(rooms, fn(r) { r }))
  static.json_response(body)
}

fn index_page(context: Context) -> Response(ResponseData) {
  // Build room list for initial render
  let rooms = case group.topics(context.groups, "public") {
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
      <> "\"><span class=\"room-hash\">#</span>"
      <> "<span class=\"room-name\">"
      <> name
      <> "</span>"
      <> "<span class=\"room-count\" data-room-count=\""
      <> name
      <> "\" aria-label=\"User count unavailable for "
      <> name
      <> "\">–</span></li>"
    })
    |> string.join("")

  let html = "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Chat Rooms — beryl demo</title>
  <link rel=\"stylesheet\" href=\"" <> context.base_path <> "/static/style.css\">
</head>
<body>
  <div id=\"app\" data-base-path=\"" <> context.base_path <> "\">
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
  <script src=\"" <> context.base_path <> "/static/app.js\"></script>
</body>
</html>"

  static.html_response(html)
}
