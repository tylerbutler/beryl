import beryl
import example_helpers/static
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(channels: beryl.Channels, base_path: String)
}

pub fn handle_request(
  req: Request(Connection),
  ctx: Context,
) -> Response(ResponseData) {
  case request.path_segments(req) {
    ["healthz"] -> healthz()
    _ -> {
      use <- static.serve_static(
        req,
        under: ctx.base_path <> "/static",
        from: static.priv_static("cursors"),
      )

      case static.match_prefix(req, ctx.base_path) {
        Ok([]) -> index_page(ctx)
        _ -> static.not_found()
      }
    }
  }
}

fn healthz() -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string("ok")))
}

fn index_page(ctx: Context) -> Response(ResponseData) {
  let base = ctx.base_path
  let html = "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Collaborative Cursors — beryl demo</title>
  <link rel=\"stylesheet\" href=\"" <> base <> "/static/style.css\">
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
  <script src=\"" <> base <> "/static/app.js\"></script>
</body>
</html>"

  static.html_response(html)
}
