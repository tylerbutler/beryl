//// Bounded test client. Gramps owns the WebSocket and compression codecs;
//// only passive TCP connection and exception-safe cleanup need test FFI.

import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import glisten/socket
import glisten/tcp
import gramps/websocket
import gramps/websocket/compression

pub type Client {
  Client(socket: socket.Socket, codec: compression.Compression)
}

@external(erlang, "beryl_mist_transport_test_ffi", "ensuring")
pub fn ensuring(cleanup: fn() -> Nil, action: fn() -> a) -> a

@external(erlang, "beryl_mist_transport_test_ffi", "connect_tcp")
fn connect_tcp(port: Int) -> Result(socket.Socket, socket.SocketReason)

@external(erlang, "beryl_mist_transport_test_ffi", "stop_supervisor")
pub fn stop_supervisor(pid: process.Pid) -> Nil

pub const offer = "permessage-deflate"

pub fn with_client(
  port: Int,
  offers: List(String),
  action: fn(Client, List(#(String, String))) -> Nil,
) -> Nil {
  let assert Ok(connection) = connect_tcp(port)
  use <- ensuring(fn() {
    let assert Ok(Nil) = tcp.close(connection)
    Nil
  })
  let codec = compression.init(compression.ContextTakeover(False, False))
  use <- ensuring(fn() {
    compression.close(codec.inflate)
    compression.close(codec.deflate)
  })
  let extensions =
    offers
    |> list.map(fn(value) { "Sec-WebSocket-Extensions: " <> value <> "\r\n" })
    |> string.concat
  let request =
    "GET /socket HTTP/1.1\r\nHost: 127.0.0.1\r\n"
    <> "Upgrade: websocket\r\nConnection: Upgrade\r\n"
    <> "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
    <> "Sec-WebSocket-Version: 13\r\nX-Compression-Test: original\r\n"
    <> extensions
    <> "\r\n"
  let assert Ok(Nil) = tcp.send(connection, bytes_tree.from_string(request))
  let headers = read_headers(connection, "", 16)
  let assert [status, ..lines] = string.split(headers, "\r\n")
  status |> should.equal("HTTP/1.1 101 Switching Protocols")
  let headers =
    list.filter_map(lines, fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) -> Ok(#(string.lowercase(name), string.trim(value)))
        Error(Nil) -> Error(Nil)
      }
    })
  list.key_find(headers, "sec-websocket-accept")
  |> should.equal(Ok(websocket.parse_websocket_key("dGhlIHNhbXBsZSBub25jZQ==")))
  action(Client(connection, codec), headers)
}

fn read_headers(
  connection: socket.Socket,
  buffered: String,
  remaining: Int,
) -> String {
  { string.byte_size(buffered) <= 4096 } |> should.be_true
  case string.ends_with(buffered, "\r\n\r\n"), remaining > 0 {
    True, _ -> buffered
    False, True -> {
      // The fixture's init has no effects, so no WebSocket frames can precede
      // the first client send. Read bounded chunks, not 4096 timed byte reads.
      let assert Ok(chunk) = tcp.receive_timeout(connection, 0, 1000)
      let assert Ok(text) = bit_array.to_string(chunk)
      read_headers(connection, buffered <> text, remaining - 1)
    }
    False, False -> panic as "oversized handshake"
  }
}

pub fn send_text(client: Client, text: String, compressed: Bool) -> Nil {
  let context = case compressed {
    True -> Some(client.codec.deflate)
    False -> None
  }
  let assert Ok(Nil) =
    tcp.send(
      client.socket,
      websocket.encode_text_frame(text, context, Some(<<0, 0, 0, 0>>)),
    )
  Nil
}

pub fn send_binary(client: Client, data: BitArray, compressed: Bool) -> Nil {
  let context = case compressed {
    True -> Some(client.codec.deflate)
    False -> None
  }
  let assert Ok(Nil) =
    tcp.send(
      client.socket,
      websocket.encode_binary_frame(data, context, Some(<<0, 0, 0, 0>>)),
    )
  Nil
}

pub fn receive_text(client: Client, compressed: Bool) -> String {
  let assert Ok(frame) = receive_frame(client, compressed)
  let assert websocket.Data(websocket.TextFrame(data)) = frame
  let assert Ok(text) = bit_array.to_string(data)
  text
}

pub fn receive_binary(client: Client, compressed: Bool) -> BitArray {
  let assert Ok(frame) = receive_frame(client, compressed)
  let assert websocket.Data(websocket.BinaryFrame(data)) = frame
  data
}

pub fn assert_rejected(client: Client) -> Nil {
  case receive_frame(client, False) {
    Ok(websocket.Control(websocket.CloseFrame(websocket.ProtocolError(_))))
    | Error(socket.Closed) -> Nil
    _ -> panic as "expected protocol close or TCP close"
  }
}

fn receive_frame(
  client: Client,
  compressed: Bool,
) -> Result(websocket.Frame, socket.SocketReason) {
  case tcp.receive_timeout(client.socket, 2, 1000) {
    Error(reason) -> Error(reason)
    Ok(header) -> {
      let assert <<_:8, 0:1, size:7>> = header
      let #(extra, length) = case size {
        126 -> {
          let assert Ok(extra) = tcp.receive_timeout(client.socket, 2, 1000)
          let assert <<length:16>> = extra
          #(extra, length)
        }
        127 -> panic as "fixture reply exceeds bounded frame size"
        size -> #(<<>>, size)
      }
      { length <= 4096 } |> should.be_true
      let payload = case length {
        0 -> <<>>
        _ -> {
          let assert Ok(payload) =
            tcp.receive_timeout(client.socket, length, 1000)
          payload
        }
      }
      let context = case compressed {
        True -> Some(client.codec.inflate)
        False -> None
      }
      let assert Ok(#(websocket.Complete(frame), <<>>)) =
        websocket.decode_frame(
          <<header:bits, extra:bits, payload:bits>>,
          context,
        )
      Ok(frame)
    }
  }
}
