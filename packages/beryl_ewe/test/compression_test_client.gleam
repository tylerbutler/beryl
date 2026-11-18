//// HPACK and WebSocket framing/compression use the locked typed dependencies.
//// Raw TCP is needed to control duplicate offers and unnegotiated RSV1.

import alpacki
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import gleeunit/should
import glisten/socket
import glisten/tcp
import websocks

pub type Protocol {
  Http1
  Http2
}

pub type Client {
  Client(
    socket: socket.Socket,
    protocol: Protocol,
    plain: websocks.Context,
    compressed: websocks.Context,
  )
}

@external(erlang, "beryl_ewe_transport_test_ffi", "ensuring")
pub fn ensuring(cleanup: fn() -> Nil, action: fn() -> a) -> a

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_tcp")
fn connect_tcp(port: Int) -> Result(socket.Socket, socket.SocketReason)

@external(erlang, "beryl_ewe_transport_test_ffi", "stop_supervisor")
pub fn stop_supervisor(pid: process.Pid) -> Nil

pub const offer =
  "permessage-deflate; client_no_context_takeover; server_no_context_takeover"

pub fn with_client(
  protocol: Protocol,
  port: Int,
  offers: List(String),
  action: fn(Client, List(#(String, String))) -> Nil,
) {
  let assert Ok(connection) = connect_tcp(port)
  use <- ensuring(fn() {
    let assert Ok(Nil) = tcp.close(connection)
    Nil
  })
  let plain = websocks.create_context(None, websocks.Client)
  let compressed =
    websocks.create_context(
      Some(websocks.get_compression_extensions(offer)),
      websocks.Client,
    )
    |> websocks.with_limits(websocks.Limits(4096, 4096))
  use <- ensuring(fn() {
    websocks.close_context(plain)
    websocks.close_context(compressed)
  })
  let headers = case protocol {
    Http1 -> handshake_http1(connection, offers)
    Http2 -> handshake_http2(connection, port, offers)
  }
  action(Client(connection, protocol, plain, compressed), headers)
}

fn handshake_http1(connection: socket.Socket, offers: List(String)) {
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
  send_tcp(connection, bit_array.from_string(request))
  let assert [status, ..lines] =
    read_headers(connection, "", 16) |> string.split("\r\n")
  status |> should.equal("HTTP/1.1 101 Switching Protocols")
  let headers =
    list.filter_map(lines, fn(line) {
      case string.split_once(line, ":") {
        Ok(#(name, value)) -> Ok(#(string.lowercase(name), string.trim(value)))
        Error(Nil) -> Error(Nil)
      }
    })
  list.key_find(headers, "sec-websocket-accept")
  |> should.equal(Ok(websocks.compute_accept("dGhlIHNhbXBsZSBub25jZQ==")))
  headers
}

fn read_headers(connection: socket.Socket, buffered: String, remaining: Int) {
  { string.byte_size(buffered) <= 4096 } |> should.be_true
  case string.ends_with(buffered, "\r\n\r\n"), remaining > 0 {
    True, _ -> buffered
    False, True -> {
      // Init emits no frames, so the handshake is the only pending response.
      let assert Ok(chunk) = tcp.receive_timeout(connection, 0, 1000)
      let assert Ok(text) = bit_array.to_string(chunk)
      read_headers(connection, buffered <> text, remaining - 1)
    }
    False, False -> panic as "oversized handshake"
  }
}

fn handshake_http2(connection: socket.Socket, port: Int, offers: List(String)) {
  send_tcp(connection, <<
    "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n":utf8,
    http2_frame(4, 0, 0, <<>>):bits,
  >>)
  let assert Ok(settings) = http2_wait(connection, 4, 16)
  enables_connect(settings) |> should.be_true
  let fields =
    list.append(
      [
        #(":method", "CONNECT"),
        #(":protocol", "websocket"),
        #(":scheme", "http"),
        #(":path", "/socket"),
        #(":authority", "127.0.0.1:" <> int.to_string(port)),
        #("sec-websocket-version", "13"),
        #("x-compression-test", "original"),
      ],
      list.map(offers, fn(value) { #("sec-websocket-extensions", value) }),
    )
    |> list.map(fn(field) {
      alpacki.HeaderField(
        bit_array.from_string(field.0),
        bit_array.from_string(field.1),
        alpacki.WithoutIndexing,
      )
    })
  let #(block, _) =
    alpacki.encode_header_block(fields, alpacki.new_dynamic(4096), False)
  send_tcp(connection, http2_frame(1, 4, 1, block))
  let assert Ok(block) = http2_wait(connection, 1, 16)
  let assert Ok(decoded) =
    alpacki.decode_header_block(block, alpacki.new_dynamic(4096))
  decoded.remaining |> should.equal(<<>>)
  let headers =
    list.map(decoded.headers, fn(field) {
      let assert Ok(name) = bit_array.to_string(field.0)
      let assert Ok(value) = bit_array.to_string(field.1)
      #(name, value)
    })
  list.key_find(headers, ":status") |> should.equal(Ok("200"))
  headers
}

pub fn send_text(client: Client, text: String, compressed: Bool) {
  let context = context(client, compressed)
  send(
    client,
    websocks.encode_text_frame(
      bit_array.from_string(text),
      context,
      Some(<<0, 0, 0, 0>>),
    ),
  )
}

pub fn send_binary(client: Client, data: BitArray, compressed: Bool) {
  let context = context(client, compressed)
  send(
    client,
    websocks.encode_binary_frame(data, context, Some(<<0, 0, 0, 0>>)),
  )
}

fn context(client: Client, compressed: Bool) {
  case compressed {
    True -> client.compressed
    False -> client.plain
  }
}

fn send(client: Client, frame: BitArray) {
  let data = case client.protocol {
    Http1 -> frame
    Http2 -> http2_frame(0, 0, 1, frame)
  }
  send_tcp(client.socket, data)
}

fn send_tcp(connection: socket.Socket, data: BitArray) {
  let assert Ok(Nil) = tcp.send(connection, bytes_tree.from_bit_array(data))
  Nil
}

pub fn receive_text(client: Client, compressed: Bool) {
  let assert Ok(websocks.Text(data)) =
    receive_frame(client, context(client, compressed), 16)
  let assert Ok(text) = bit_array.to_string(data)
  text
}

pub fn receive_binary(client: Client, compressed: Bool) {
  let assert Ok(websocks.Binary(data)) =
    receive_frame(client, context(client, compressed), 16)
  data
}

pub fn assert_rejected(client: Client) {
  case receive_frame(client, client.plain, 16) {
    Ok(websocks.Control(websocks.Close(websocks.CloseReason(
      websocks.ProtocolError,
      _,
    ))))
    | Error(socket.Closed) -> Nil
    _ -> panic as "expected protocol rejection"
  }
}

// Each test has exactly one outstanding request/reply. Websocks retains
// partial frames across DATA/TCP reads; assert no second frame is discarded.
fn receive_frame(client: Client, context: websocks.Context, remaining: Int) {
  case remaining > 0 {
    False -> Error(socket.Timeout)
    True -> {
      let assert Ok(decoded) = websocks.next_frame(context)
      case decoded {
        websocks.Decoded(frame, rest) -> {
          websocks.is_empty_context(rest) |> should.be_true
          Ok(frame)
        }
        websocks.MoreData(context) -> {
          let data = case client.protocol {
            Http1 -> tcp.receive_timeout(client.socket, 0, 1000)
            Http2 -> http2_wait(client.socket, 0, 16)
          }
          use data <- result.try(data)
          { bit_array.byte_size(data) <= 4096 } |> should.be_true
          receive_frame(
            client,
            websocks.push_data(context, data),
            remaining - 1,
          )
        }
      }
    }
  }
}

fn http2_frame(kind: Int, flags: Int, stream: Int, payload: BitArray) {
  <<bit_array.byte_size(payload):24, kind, flags, stream:32, payload:bits>>
}

// Small, unpadded stream-1 fixtures only. Count and size limits and passive
// one-second reads bound control traffic as well as payload traffic.
fn http2_wait(connection: socket.Socket, wanted: Int, remaining: Int) {
  case remaining > 0 {
    False -> Error(socket.Timeout)
    True -> {
      use header <- result.try(tcp.receive_timeout(connection, 9, 1000))
      let assert <<length:24, kind, flags, 0:1, stream:31>> = header
      { length <= 16_384 } |> should.be_true
      let payload = case length {
        0 -> Ok(<<>>)
        _ -> tcp.receive_timeout(connection, length, 1000)
      }
      use payload <- result.try(payload)
      case kind, flags, stream {
        4, 0, 0 -> {
          send_tcp(connection, http2_frame(4, 1, 0, <<>>))
          case wanted == 4 {
            True -> Ok(payload)
            False -> http2_wait(connection, wanted, remaining - 1)
          }
        }
        4, 1, 0 | 8, 0, _ -> http2_wait(connection, wanted, remaining - 1)
        6, 0, 0 -> {
          send_tcp(connection, http2_frame(6, 1, 0, payload))
          http2_wait(connection, wanted, remaining - 1)
        }
        1, 4, 1 | 1, 5, 1 if wanted == 1 -> Ok(payload)
        0, 0, 1 | 0, 1, 1 if wanted == 0 -> Ok(payload)
        3, _, 1 -> Error(socket.Closed)
        _, _, _ ->
          panic as {
            "unexpected HTTP/2 frame kind="
            <> int.to_string(kind)
            <> " flags="
            <> int.to_string(flags)
            <> " stream="
            <> int.to_string(stream)
          }
      }
    }
  }
}

fn enables_connect(settings: BitArray) {
  case settings {
    <<8:16, 1:32, _:bits>> -> True
    <<_:16, _:32, rest:bits>> -> enables_connect(rest)
    _ -> False
  }
}
