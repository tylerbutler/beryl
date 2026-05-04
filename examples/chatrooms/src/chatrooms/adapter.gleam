/// Minimal Wisp-to-Mist adapter for HTTP routing.
import exception
import gleam/bytes_tree
import gleam/http/request
import gleam/http/response
import gleam/option
import gleam/result
import gleam/string
import mist
import wisp
import wisp/internal

/// Convert a Wisp request handler into a Mist-compatible handler function.
pub fn handler(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
) -> fn(request.Request(mist.Connection)) ->
  response.Response(mist.ResponseData) {
  fn(mist_request: request.Request(_)) {
    let connection =
      internal.make_connection(mist_body_reader(mist_request), secret_key_base)
    let wisp_request = request.set_body(mist_request, connection)

    use <- exception.defer(fn() {
      let assert Ok(_) = wisp.delete_temporary_files(wisp_request)
    })

    let resp = handler(wisp_request)
    case resp.body {
      wisp.Text(text) ->
        response.set_body(resp, mist.Bytes(bytes_tree.from_string(text)))
      wisp.Bytes(bytes) -> response.set_body(resp, mist.Bytes(bytes))
      wisp.File(path:, offset:, limit:) ->
        mist_send_file(resp, path, offset, limit)
    }
  }
}

fn mist_body_reader(
  request: request.Request(mist.Connection),
) -> internal.Reader {
  case mist.stream(request) {
    Error(_) -> fn(_) { Ok(internal.ReadingFinished) }
    Ok(stream) -> fn(size) { wrap_mist_chunk(stream(size)) }
  }
}

fn wrap_mist_chunk(
  chunk: Result(mist.Chunk, mist.ReadError),
) -> Result(internal.Read, Nil) {
  chunk
  |> result.replace_error(Nil)
  |> result.map(fn(chunk) {
    case chunk {
      mist.Done -> internal.ReadingFinished
      mist.Chunk(data, consume) ->
        internal.Chunk(data, fn(size) { wrap_mist_chunk(consume(size)) })
    }
  })
}

fn mist_send_file(
  resp: response.Response(wisp.Body),
  path: String,
  offset: Int,
  limit: option.Option(Int),
) -> response.Response(mist.ResponseData) {
  case mist.send_file(path, offset:, limit:) {
    Ok(body) -> response.set_body(resp, body)
    Error(error) -> {
      wisp.log_error(string.inspect(error))
      response.new(500)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}
