/// Minimal wisp-to-mist adapter.
/// Bridges wisp request handlers to mist's HTTP server.
/// Based on the wisp_mist package from the wisp repository.
///
/// TODO: Once the wisp WebSocket PR lands and wisp_mist is published to Hex
/// with WebSocket support, replace this module with the published wisp_mist
/// package and remove the mist/exception direct dependencies from gleam.toml.
///
/// NOTE: mist v5 requires WebSocket sends to come from the owning process.
/// This adapter uses a Subject+Selector relay so beryl's coordinator (which
/// runs in its own process) can send messages cross-process. Send requests
/// are forwarded to the WebSocket process as Custom messages, which then
/// call mist.send_text_frame from the correct process.
import exception
import gleam/bytes_tree
import gleam/erlang/process
import gleam/http/request.{type Request as HttpRequest}
import gleam/http/response.{type Response as HttpResponse}
import gleam/option.{Some}
import gleam/result
import gleam/string
import mist
import wisp
import wisp/internal
import wisp/websocket

/// Messages relayed to the WebSocket process for cross-process sends.
type SendRequest {
  SendText(String)
  SendBinary(BitArray)
}

/// Convert a wisp request handler into a mist-compatible handler function.
///
/// ```gleam
/// handle_request
/// |> adapter.handler(secret_key_base)
/// |> mist.new
/// |> mist.port(8000)
/// |> mist.start
/// ```
pub fn handler(
  handler: fn(wisp.Request) -> wisp.Response,
  secret_key_base: String,
) -> fn(HttpRequest(mist.Connection)) -> HttpResponse(mist.ResponseData) {
  fn(mist_request: HttpRequest(_)) {
    let connection =
      internal.make_connection(mist_body_reader(mist_request), secret_key_base)
    let wisp_request = request.set_body(mist_request, connection)

    use <- exception.defer(fn() {
      let assert Ok(_) = wisp.delete_temporary_files(wisp_request)
    })

    let resp = handler(wisp_request)

    case resp.body {
      wisp.WebSocket(upgrade) -> mist_websocket_upgrade(mist_request, upgrade)
      wisp.Text(text) ->
        response.set_body(resp, mist.Bytes(bytes_tree.from_string(text)))
      wisp.Bytes(bytes) -> response.set_body(resp, mist.Bytes(bytes))
      wisp.File(path:, offset:, limit:) ->
        mist_send_file(resp, path, offset, limit)
    }
  }
}

fn mist_body_reader(request: HttpRequest(mist.Connection)) -> internal.Reader {
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
  resp: HttpResponse(wisp.Body),
  path: String,
  offset: Int,
  limit: option.Option(Int),
) -> HttpResponse(mist.ResponseData) {
  case mist.send_file(path, offset:, limit:) {
    Ok(body) -> response.set_body(resp, body)
    Error(error) -> {
      wisp.log_error(string.inspect(error))
      response.new(500)
      |> response.set_body(mist.Bytes(bytes_tree.new()))
    }
  }
}

/// Wrapper state that holds the wisp WebSocket state plus a Subject for
/// receiving cross-process send requests.
type AdapterState(inner) {
  AdapterState(inner: inner, send_subject: process.Subject(SendRequest))
}

fn mist_websocket_upgrade(
  request: HttpRequest(mist.Connection),
  upgrade: wisp.WebSocketUpgrade,
) -> HttpResponse(mist.ResponseData) {
  let ws = wisp.recover(upgrade)
  let #(on_init, on_message, on_close) = websocket.extract_callbacks(ws)

  mist.websocket(
    request:,
    on_init: fn(_mist_connection) {
      // Create a Subject for cross-process send requests.
      // Other processes (e.g., beryl's coordinator) send to this Subject;
      // mist delivers them as Custom messages in the WebSocket process.
      let send_subject = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(send_subject)

      // Create a wisp connection where send_text/send_binary route through
      // the Subject relay instead of calling mist directly. This makes them
      // safe to call from any process.
      let wisp_connection =
        websocket.make_connection(
          fn(text) {
            process.send(send_subject, SendText(text))
            Ok(Nil)
          },
          fn(binary) {
            process.send(send_subject, SendBinary(binary))
            Ok(Nil)
          },
          fn() { Ok(Nil) },
        )

      let #(inner_state, _inner_selector) = on_init(wisp_connection)
      #(AdapterState(inner: inner_state, send_subject:), Some(selector))
    },
    handler: fn(state, message, mist_connection) {
      let AdapterState(inner: inner_state, send_subject: _) = state
      case message {
        // Handle relayed send requests — these arrive as Custom messages
        // and we're now in the correct (owning) process to call mist.
        mist.Custom(SendText(text)) -> {
          let _ = mist.send_text_frame(mist_connection, text)
          mist.continue(state)
        }
        mist.Custom(SendBinary(binary)) -> {
          let _ = mist.send_binary_frame(mist_connection, binary)
          mist.continue(state)
        }

        // For all other messages, forward to the wisp handler
        _ -> {
          let wisp_connection =
            websocket.make_connection(
              fn(text) {
                // In-process send (handler context) — can call mist directly
                mist.send_text_frame(mist_connection, text)
                |> result.map_error(fn(_) { websocket.SendFailed })
              },
              fn(binary) {
                mist.send_binary_frame(mist_connection, binary)
                |> result.map_error(fn(_) { websocket.SendFailed })
              },
              fn() { Ok(Nil) },
            )

          let wisp_message = case message {
            mist.Text(text) -> websocket.Text(text)
            mist.Binary(binary) -> websocket.Binary(binary)
            mist.Closed -> websocket.Closed
            mist.Shutdown -> websocket.Shutdown
            mist.Custom(_) -> websocket.Closed
          }

          case on_message(inner_state, wisp_message, wisp_connection) {
            websocket.Continue(new_inner) ->
              mist.continue(
                AdapterState(..state, inner: new_inner),
              )
            websocket.Stop -> mist.stop()
            websocket.StopWithError(reason) -> mist.stop_abnormal(reason)
          }
        }
      }
    },
    on_close: fn(state) {
      let AdapterState(inner: inner_state, send_subject: _) = state
      on_close(inner_state)
    },
  )
}
