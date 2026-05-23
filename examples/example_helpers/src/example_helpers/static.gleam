//// Static-file and HTTP-response helpers shared by the beryl example apps.
////
//// Example apps each serve a few HTML pages, a JSON API or two, and a small
//// directory of CSS/JS assets from their `priv/static` folder. The router
//// boilerplate was identical across `chatrooms`, `cursors`, and `collab_docs`;
//// this module extracts it so each example's router shrinks to its
//// app-specific routes.

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

/// Serve files from `directory` under the URL prefix `prefix`. Falls through
/// to `handler` for non-GET requests and for paths that don't match.
pub fn serve_static(
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

/// Build a 200 HTML response from a string body.
pub fn html_response(html: String) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "text/html; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(html)))
}

/// Build a 200 JSON response from an already-serialized JSON string body.
pub fn json_response(json: String) -> Response(ResponseData) {
  response.new(200)
  |> response.set_header("content-type", "application/json; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json)))
}

/// Build a plain `404 Not found` response.
pub fn not_found() -> Response(ResponseData) {
  response.new(404)
  |> response.set_body(mist.Bytes(bytes_tree.from_string("Not found")))
}

/// Strip consecutive leading slashes from a path.
pub fn drop_leading_slashes(path: String) -> String {
  case path {
    "/" <> rest -> drop_leading_slashes(rest)
    _ -> path
  }
}

/// If `req`'s path begins with `prefix` (matched on whole path segments),
/// return the remaining segments after the prefix; otherwise Error(Nil).
/// An empty `prefix` matches everything and returns all path segments.
pub fn match_prefix(
  req: Request(Connection),
  prefix: String,
) -> Result(List(String), Nil) {
  let segs = request.path_segments(req)
  let prefix_segs =
    prefix
    |> drop_leading_slashes
    |> string.split("/")
    |> list.filter(fn(s) { s != "" })
  strip_prefix(segs, prefix_segs)
}

fn strip_prefix(
  segs: List(String),
  prefix: List(String),
) -> Result(List(String), Nil) {
  case prefix, segs {
    [], rest -> Ok(rest)
    [p, ..ps], [s, ..ss] if p == s -> strip_prefix(ss, ps)
    _, _ -> Error(Nil)
  }
}

/// Guess a content-type for a path by its extension. Defaults to
/// `application/octet-stream` for unknown extensions.
pub fn mime_type_for(path: String) -> String {
  case string.split(path, ".") |> list.last {
    Ok("css") -> "text/css; charset=utf-8"
    Ok("js") -> "application/javascript; charset=utf-8"
    Ok("mjs") -> "application/javascript; charset=utf-8"
    Ok("html") -> "text/html; charset=utf-8"
    Ok("json") -> "application/json; charset=utf-8"
    _ -> "application/octet-stream"
  }
}

/// Resolve `<priv>/static` for an OTP application. Crashes if the application
/// isn't loaded — examples always have their own priv tree at runtime.
pub fn priv_static(app_name: String) -> String {
  let assert Ok(priv) = application.priv_directory(app_name)
  priv <> "/static"
}
