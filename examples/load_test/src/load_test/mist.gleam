import beryl
import gleam/bytes_tree
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import load_test/http
import mist.{type Connection, type ResponseData}

pub fn handle(
  request: Request(Connection),
  channels: beryl.Channels,
) -> Response(ResponseData) {
  case request.path_segments(request) {
    ["health"] -> from_endpoint(http.health())
    ["stats"] -> from_endpoint(http.stats(channels))
    _ -> response.new(404) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
}

pub fn from_endpoint(endpoint: http.EndpointResult) -> Response(ResponseData) {
  response.new(endpoint.status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(mist.Bytes(bytes_tree.from_string(endpoint.body)))
}
