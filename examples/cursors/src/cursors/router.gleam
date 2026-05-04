import beryl
import beryl/presence
import wisp

pub type Context {
  Context(channels: beryl.Channels, presence: presence.Presence)
}

pub fn handle_request(req: wisp.Request, _ctx: Context) -> wisp.Response {
  // Serve static files from priv/static
  use <- wisp.serve_static(req, under: "/static", from: priv_directory())

  // Route HTTP requests
  case wisp.path_segments(req) {
    [] -> index_page()
    _ -> wisp.not_found()
  }
}

fn index_page() -> wisp.Response {
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
  <script src=\"https://unpkg.com/phoenix@1.7.20/priv/static/phoenix.js\"></script>
  <script src=\"/static/app.js\"></script>
</body>
</html>"

  wisp.html_response(html, 200)
}

fn priv_directory() -> String {
  let assert Ok(priv) = wisp.priv_directory("cursors")
  priv <> "/static"
}
