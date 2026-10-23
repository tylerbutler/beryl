import example_helper/static
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import mist.{type Connection, type ResponseData}

pub fn handle_request(
  req: Request(Connection),
  static_directory: String,
) -> Response(ResponseData) {
  case static.match_prefix(req, "") {
    Ok([]) -> static.html_response(index_html())
    _ ->
      static.serve_static(
        req,
        under: "/static",
        from: static_directory,
        next: static.not_found,
      )
  }
}

pub fn index_html() -> String {
  "<!DOCTYPE html>
<html lang=\"en\">
<head>
  <meta charset=\"UTF-8\">
  <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
  <title>Lustre Todo — beryl example</title>
  <link rel=\"stylesheet\" href=\"/static/style.css\">
</head>
<body>
  <main id=\"app\"></main>
  <script type=\"module\" src=\"/static/todo_client.js\"></script>
</body>
</html>"
}
