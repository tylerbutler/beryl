import example_helper/static
import gleam/bytes_tree
import gleam/http
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import lustre_presence/auth
import mist.{type Connection, type ResponseData}

pub type Context {
  Context(secret: BitArray, static_directory: String)
}

pub fn handle_request(
  http_request: Request(Connection),
  context: Context,
) -> Response(ResponseData) {
  use <- static.serve_static(
    http_request,
    under: "/static",
    from: context.static_directory,
  )

  case http_request.method, request.path_segments(http_request) {
    http.Get, [] -> dashboard_or_login(http_request, context)
    http.Get, ["login", user_id] -> login(user_id, context)
    http.Get, ["logout"] -> logout()
    _, _ -> static.not_found()
  }
}

fn dashboard_or_login(
  http_request: Request(Connection),
  context: Context,
) -> Response(ResponseData) {
  case auth.authenticate_request(http_request, context.secret) {
    Ok(user) -> dashboard(user)
    Error(Nil) -> login_page()
  }
}

fn login(user_id: String, context: Context) -> Response(ResponseData) {
  case auth.find_user(user_id) {
    Error(Nil) -> static.not_found()
    Ok(user) ->
      redirect("/")
      |> response.set_header(
        "set-cookie",
        auth.session_cookie(user, context.secret),
      )
  }
}

fn logout() -> Response(ResponseData) {
  redirect("/")
  |> response.set_header(
    "set-cookie",
    "beryl_session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0",
  )
}

fn login_page() -> Response(ResponseData) {
  page(
    "Sign in",
    "<main><h1>Sign in</h1><p>Select a demo user.</p>"
      <> "<ul><li><a href=\"/login/ada\">Ada Lovelace</a></li>"
      <> "<li><a href=\"/login/grace\">Grace Hopper</a></li></ul></main>",
  )
}

fn dashboard(user: auth.User) -> Response(ResponseData) {
  page(
    "Online users",
    "<header><p>Signed in as "
      <> user.name
      <> " - <a href=\"/logout\">Sign out</a></p></header>"
      <> "<div id=\"app\"></div>"
      <> "<script type=\"module\" src=\"/static/lustre_presence_client.js\"></script>",
  )
}

fn page(title: String, body: String) -> Response(ResponseData) {
  static.html_response(
    "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">"
    <> "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"
    <> "<title>"
    <> title
    <> " - beryl</title></head><body>"
    <> body
    <> "</body></html>",
  )
}

fn redirect(location: String) -> Response(ResponseData) {
  response.new(303)
  |> response.set_header("location", location)
  |> response.set_body(mist.Bytes(bytes_tree.new()))
}
