//// Static-file and HTTP-response helpers shared by the beryl example apps.
////
//// Example apps each serve a few HTML pages, a JSON API or two, and a small
//// directory of CSS/JS assets from their `priv/static` folder. The router
//// boilerplate was identical across `chatroom`, `cursor`, and
//// `collab_document`;
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
  http_request: Request(Connection),
  under prefix: String,
  from directory: String,
  next handler: fn() -> Response(ResponseData),
) -> Response(ResponseData) {
  let path = drop_leading_slashes(http_request.path)
  let prefix = drop_leading_slashes(prefix)

  case string.starts_with(path, prefix) {
    False -> handler()
    True ->
      case http_request.method {
        http.Get -> {
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
                  |> response.set_header(
                    "content-type",
                    mime_type_for(file_path),
                  )
                  |> response.set_body(body)
                Error(mist.UnknownFileError) ->
                  response.new(500)
                  |> response.set_body(mist.Bytes(bytes_tree.new()))
                Error(mist.IsDir)
                | Error(mist.NoAccess)
                | Error(mist.NoEntry) -> not_found()
              }
            }
          }
        }
        http.Post
        | http.Head
        | http.Put
        | http.Delete
        | http.Trace
        | http.Connect
        | http.Options
        | http.Patch
        | http.Other(_) -> handler()
      }
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

/// If `http_request`'s path begins with `prefix` (matched on whole path segments),
/// return the remaining segments after the prefix; otherwise Error(Nil).
/// An empty `prefix` matches everything and returns all path segments.
pub fn match_prefix(
  http_request: Request(Connection),
  prefix: String,
) -> Result(List(String), Nil) {
  let segments = request.path_segments(http_request)
  let prefix_segments =
    prefix
    |> drop_leading_slashes
    |> string.split("/")
    |> list.filter(fn(segment) { segment != "" })
  strip_prefix(segments, prefix_segments)
}

fn strip_prefix(
  segments: List(String),
  prefix: List(String),
) -> Result(List(String), Nil) {
  case prefix, segments {
    [], rest -> Ok(rest)
    [prefix_segment, ..remaining_prefix], [segment, ..remaining_segments]
      if prefix_segment == segment
    -> strip_prefix(remaining_segments, remaining_prefix)
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
    Error(_) | Ok(_) -> "application/octet-stream"
  }
}

/// Resolve `<priv>/static` for an OTP application.
///
/// Returns `Error(Nil)` if the application is not loaded. Resolve this once
/// at application startup and pass the directory to the request handler.
pub fn priv_static(app_name: String) -> Result(String, Nil) {
  application.priv_directory(app_name)
  |> result.map(fn(private_directory) { private_directory <> "/static" })
}
