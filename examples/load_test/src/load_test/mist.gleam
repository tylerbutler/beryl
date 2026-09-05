import beryl
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import load_test/http
import mist.{type Connection, type ResponseData}

pub fn handle(
  request: Request(Connection),
  channels: beryl.Sockets,
) -> Response(ResponseData) {
  case request.path_segments(request) {
    ["health"] -> endpoint_to_response(http.health())
    ["stats"] -> endpoint_to_response(http.stats(channels))
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

pub fn endpoint_to_response(
  endpoint: http.EndpointResult,
) -> Response(ResponseData) {
  response.new(endpoint.status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(endpoint.body)))
}
