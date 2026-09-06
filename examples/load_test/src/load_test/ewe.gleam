import beryl
import ewe.{type Connection, type ResponseBody}
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import load_test/http

pub fn handle(
  request: Request(Connection),
  channels: beryl.Sockets,
) -> Response(ResponseBody) {
  case request.path_segments(request) {
    ["health"] -> endpoint_to_response(http.health())
    ["stats"] -> endpoint_to_response(http.stats(channels))
    _ -> response.new(404) |> response.set_body(ewe.Empty)
  }
}

pub fn endpoint_to_response(
  endpoint: http.EndpointResult,
) -> Response(ResponseBody) {
  response.new(endpoint.status)
  |> response.set_header("content-type", "application/json")
  |> response.set_body(ewe.TextData(endpoint.body))
}
