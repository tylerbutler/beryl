import beryl
import beryl/group
import example_helpers/session_presence
import example_helpers/static
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
  )
}

pub fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  use <- static.serve_static(
    req,
    under: ctx.base_path <> "/static",
    from: static.priv_static("chatrooms"),
  )

  case static.match_prefix(req, ctx.base_path) {
    Ok([]) -> index_page(ctx)
    Ok(["api", "rooms"]) -> rooms_api(ctx)
    _ -> static.not_found()
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
        let user_count = session_presence.count(ctx.presence, topic)
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
  <link rel=\"stylesheet\" href=\"" <> ctx.base_path <> "/static/style.css\">
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
  <script src=\"" <> ctx.base_path <> "/static/app.js\"></script>
</body>
</html>"

  static.html_response(html)
}
