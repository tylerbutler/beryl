import beryl
import beryl/group
import beryl/presence
import beryl/transport/websocket
import gleam/http/request
import gleam/json
import gleam/list
import gleam/result
import gleam/set
import gleam/string
import wisp

pub type Context {
  Context(
    channels: beryl.Channels,
    presence: presence.Presence,
    groups: group.Groups,
  )
}

pub fn handle_request(req: wisp.Request, ctx: Context) -> wisp.Response {
  // WebSocket upgrade with on_connect authentication
  let ws_config =
    websocket.default_config("/socket/websocket")
    |> websocket.with_on_connect(fn(request) {
      // Check for valid auth token in query params
      case get_query_param(request, "token") {
        Ok("beryl-demo") -> Ok(Nil)
        _ -> Error(Nil)
      }
    })

  use <- websocket.upgrade(req, ctx.channels.coordinator, ws_config)

  // Serve static files from priv/static
  use <- wisp.serve_static(req, under: "/static", from: priv_directory())

  // Route HTTP requests
  case wisp.path_segments(req) {
    [] -> index_page(ctx)
    ["api", "rooms"] -> rooms_api(ctx)
    _ -> wisp.not_found()
  }
}

fn rooms_api(ctx: Context) -> wisp.Response {
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
  wisp.json_response(body, 200)
}

fn get_query_param(req: wisp.Request, name: String) -> Result(String, Nil) {
  case request.get_query(req) {
    Ok(params) ->
      list.find(params, fn(pair) { pair.0 == name })
      |> result.map(fn(pair) { pair.1 })
    Error(_) -> Error(Nil)
  }
}

fn index_page(ctx: Context) -> wisp.Response {
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
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\"></script>
  <script src=\"/static/app.js\"></script>
</body>
</html>"

  wisp.html_response(html, 200)
}

fn priv_directory() -> String {
  let assert Ok(priv) = wisp.priv_directory("chatrooms")
  priv <> "/static"
}
