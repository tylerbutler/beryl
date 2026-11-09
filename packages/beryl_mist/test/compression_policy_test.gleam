//// Real Mist HTTP/1 upgrades, independently exercising both entry points.

import beryl
import beryl/socket
import beryl/transport/server
import beryl/wire
import beryl/wire/codec
import beryl_mist as adapter
import compression_test_client as client
import gleam/bytes_tree
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import mist

type Entry {
  Handler
  Direct
}

type Delivery {
  Text(String)
  Binary(BitArray)
}

const join = "[\"join\",\"join\",\"room:test\",\"phx_join\",{}]"

const text =
  "[\"join\",\"message\",\"room:test\",\"echo\",{\"value\":\"small text fixture\"}]"

const binary = <<0, 1, 2, 3, 127, 128, 254, 255>>

pub fn default_declines_duplicate_offers_and_delivers_plain_frames_test() {
  list.each([Handler, Direct], fn(entry) {
    use port, auth, seeds, delivered <- with_server(entry, False)
    use connection, headers <- client.with_client(port, [
      client.offer,
      client.offer,
    ])
    extension_headers(headers) |> should.equal([])
    assert_original_headers(auth, seeds, [client.offer, client.offer])
    exercise_traffic(connection, delivered, False)
  })
}

pub fn default_rejects_unnegotiated_compressed_text_without_delivery_test() {
  assert_unnegotiated(False)
}

pub fn default_rejects_unnegotiated_compressed_binary_without_delivery_test() {
  assert_unnegotiated(True)
}

pub fn explicit_opt_in_negotiates_and_delivers_compressed_frames_test() {
  list.each([Handler, Direct], fn(entry) {
    use port, auth, seeds, delivered <- with_server(entry, True)
    use connection, headers <- client.with_client(port, [client.offer])
    let assert [#(_, negotiated)] = extension_headers(headers)
    string.contains(negotiated, "permessage-deflate") |> should.be_true
    assert_original_headers(auth, seeds, [client.offer])
    exercise_traffic(connection, delivered, True)
  })
}

pub fn opted_in_without_offer_stays_uncompressed_test() {
  list.each([Handler, Direct], fn(entry) {
    use port, auth, seeds, delivered <- with_server(entry, True)
    use connection, headers <- client.with_client(port, [])
    extension_headers(headers) |> should.equal([])
    assert_original_headers(auth, seeds, [])
    exercise_traffic(connection, delivered, False)
  })
}

fn assert_unnegotiated(is_binary: Bool) {
  list.each([Handler, Direct], fn(entry) {
    use port, auth, seeds, delivered <- with_server(entry, False)
    use connection, headers <- client.with_client(port, [client.offer])
    extension_headers(headers) |> should.equal([])
    assert_original_headers(auth, seeds, [client.offer])
    // Join first so a permissive binary path would actually reach the app.
    client.send_text(connection, join, False)
    client.receive_text(connection, False)
    |> should.equal(
      "[\"join\",\"join\",\"room:test\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
    )
    case is_binary {
      True -> client.send_binary(connection, binary, True)
      False -> client.send_text(connection, text, True)
    }
    client.assert_rejected(connection)
    // The subject selects this test's exact unique tag, never any mailbox item.
    process.receive(delivered, 100) |> should.equal(Error(Nil))
  })
}

fn exercise_traffic(
  connection: client.Client,
  delivered: process.Subject(Delivery),
  compressed: Bool,
) {
  client.send_text(connection, join, compressed)
  client.receive_text(connection, compressed)
  |> should.equal(
    "[\"join\",\"join\",\"room:test\",\"phx_reply\",{\"status\":\"ok\",\"response\":{}}]",
  )
  client.send_text(connection, text, compressed)
  process.receive(delivered, 1000)
  |> should.equal(Ok(Text("small text fixture")))
  client.receive_text(connection, compressed) |> should.equal("text reply")
  client.send_binary(connection, binary, compressed)
  process.receive(delivered, 1000) |> should.equal(Ok(Binary(binary)))
  client.receive_binary(connection, compressed) |> should.equal(binary)
  process.receive(delivered, 0) |> should.equal(Error(Nil))
}

fn extension_headers(headers: List(#(String, String))) {
  list.filter(headers, fn(header) { header.0 == "sec-websocket-extensions" })
}

fn value_decoder() {
  use value <- decode.field("value", decode.string)
  decode.success(value)
}

fn drain(subject: process.Subject(a)) -> Nil {
  case process.receive(subject, 0) {
    Ok(_) -> drain(subject)
    Error(Nil) -> Nil
  }
}

fn assert_original_headers(
  auth: process.Subject(List(#(String, String))),
  seeds: process.Subject(socket.ConnectSeed),
  offers: List(String),
) {
  let assert Ok(auth_headers) = process.receive(auth, 1000)
  let assert Ok(seed) = process.receive(seeds, 1000)
  extension_headers(auth_headers)
  |> list.map(fn(header) { header.1 })
  // Mist's HTTP parser collapses repeated header names before our handler.
  |> list.unique
  |> should.equal(list.unique(offers))
  seed.headers |> should.equal(auth_headers)
  list.key_find(seed.headers, "x-compression-test")
  |> should.equal(Ok("original"))
}

fn with_server(
  entry: Entry,
  compressed: Bool,
  action: fn(
    Int,
    process.Subject(List(#(String, String))),
    process.Subject(socket.ConnectSeed),
    process.Subject(Delivery),
  ) -> Nil,
) {
  let auth = process.new_subject()
  let seeds = process.new_subject()
  let delivered = process.new_subject()
  let phoenix = wire.phoenix_codec()
  let mixed_codec =
    codec.new(
      decode_text: wire.decode_message,
      encode_reply: codec.encode_reply(phoenix),
      encode_push: fn(_, event, _) {
        case event {
          "binary" -> Ok(codec.BinaryFrame(binary))
          _ -> Ok(codec.TextFrame("text reply"))
        }
      },
      encode_heartbeat_reply: codec.encode_heartbeat_reply(phoenix),
    )
  let assert Ok(#(channels, spec)) =
    beryl.child_spec(
      beryl.config(mixed_codec),
      init: fn(info: socket.ConnectInfo(Nil)) {
        process.send(seeds, info.seed)
        #(Nil, [])
      },
      update: fn(model, event) {
        let effects = case event {
          socket.Join(_, _, reference) -> [socket.AcceptJoin(reference, None)]
          socket.Message(topic, _, payload, _) -> {
            let assert Ok(value) = decode.run(payload, value_decoder())
            process.send(delivered, Text(value))
            [socket.Push(topic, "text", json.object([]))]
          }
          socket.Binary(topic, data) -> {
            process.send(delivered, Binary(data))
            [socket.Push(topic, "binary", json.object([]))]
          }
          socket.Closed(_, _) | socket.Info(_) -> []
        }
        socket.Next(model, effects)
      },
    )
  let assert Ok(runtime) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start
  use <- client.ensuring(fn() {
    client.stop_supervisor(runtime.pid)
    drain(auth)
    drain(seeds)
    drain(delivered)
  })
  let config = server.default_config("/socket")
  let config = case compressed {
    True -> server.with_compression(config)
    False -> config
  }
  let config =
    config
    |> server.with_on_connect(fn(request) {
      process.send(auth, request.headers)
      Ok([])
    })
  let fallback = fn(_) {
    response.new(418) |> response.set_body(mist.Bytes(bytes_tree.new()))
  }
  let handler = case entry {
    Handler -> adapter.handler(channels, config, fallback)
    Direct -> fn(request) {
      adapter.upgrade(request, channels, config, fn() { fallback(request) })
    }
  }
  let ports = process.new_subject()
  let assert Ok(listener) =
    handler
    |> mist.new
    |> mist.port(0)
    |> mist.bind("127.0.0.1")
    |> mist.after_start(fn(port, _, _) { process.send(ports, port) })
    |> mist.start
  use <- client.ensuring(fn() { client.stop_supervisor(listener.pid) })
  let assert Ok(port) = process.receive(ports, 1000)
  action(port, auth, seeds, delivered)
}
