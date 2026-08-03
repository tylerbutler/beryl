import beryl
import ewe.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import load_test/http

pub fn handle(
  request: Request(Connection),
  channels: beryl.Channels,
) -> Response(ResponseBody) {
  case request.path_segments(request) {
    ["health"] -> from_endpoint(http.health())
    ["stats"] -> from_endpoint(http.stats(channels))
    _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}

pub fn from_endpoint(endpoint: http.EndpointResult) -> Response(ResponseBody) {
  response.new(endpoint.status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(ewe.TextData(endpoint.body))
}
