import beryl
import beryl/presence
import example_helpers/static
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(channels: beryl.Channels, presence: presence.Presence)
}

pub fn handle_request(
  req: Request(Connection),
  _ctx: Context,
) -> Response(ResponseData) {
  use <- static.serve_static(
    req,
    under: "/static",
    from: static.priv_static("cursors"),
  )

  case request.path_segments(req) {
    [] -> index_page()
    _ -> static.not_found()
  }
}

fn index_page() -> Response(ResponseData) {
  let html =
    "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Collaborative Cursors — beryl demo</title>
  <link rel=\"stylesheet\" href=\"/static/style.css\">
</head>
<body>
  <div id=\"app\">
    <div id=\"canvas\">
      <div id=\"welcome\">
        <h1>🖱️ Collaborative Cursors</h1>
        <p>Move your mouse to share your cursor position in real-time.</p>
        <p class=\"hint\">Open this page in multiple tabs to see it in action.</p>
        <p class=\"powered-by\">Powered by <a href=\"https://github.com/tylerbutler/beryl\">beryl</a></p>
      </div>
    </div>
    <aside id=\"sidebar\">
      <h2>Online</h2>
      <ul id=\"user-list\"></ul>
    </aside>
  </div>
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\" integrity=\"sha384-9Rsr2KoQMtWNQakugNsDiGsZ/5eQnJHeBhiocJMdHvnyN8ifwcytSTzPpb1xydYk\" crossorigin=\"anonymous\"></script>
  <script src=\"/static/app.js\"></script>
</body>
</html>"

  static.html_response(html)
}
