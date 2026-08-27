//// HTTP router for the demo service. Provides a liveness probe and a
//// versioned status endpoint clients query before opening a WebSocket.

import beryl_demo/config
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/json
import mist.{type Connection, type ResponseData}

/// Route an incoming HTTP request to the matching handler, falling back to a
/// plain-text 404 for anything else.
pub fn handle_request(
  http_request: Request(Connection),
  service_config: config.Config,
) -> Response(ResponseData) {
  case request.path_segments(http_request) {
    ["healthz"] -> text_response(200, "ok")
    ["v1", "status"] ->
      json_response(
        200,
        json.object([
          #("status", json.string("ok")),
          #("compatibility_version", json.int(config.compatibility_version)),
          #("beryl_version", json.string(service_config.beryl_version)),
          #("scenarios", json.array([config.scenario], json.string)),
        ]),
      )
    _ -> text_response(404, "not found")
  }
}

fn text_response(status: Int, body: String) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "text/plain; charset=utf-8")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(body)))
}

fn json_response(status: Int, body: json.Json) -> Response(ResponseData) {
  response.new(status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(json.to_string(body))))
}
