import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/result
import gleam/string
import gleeunit/should
import glisten/socket
import glisten/socket/options
import glisten/tcp

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_websocket")
fn connect_websocket(port: Int, path: String) -> Result(socket.Socket, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "connect_websocket_with_origin")
fn connect_websocket_with_origin(
  port: Int,
  path: String,
  origin: String,
) -> Result(socket.Socket, Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "close")
fn close_websocket(socket: socket.Socket) -> Nil

@external(erlang, "beryl_ewe_transport_test_ffi", "coalesced_upgrade_frames")
fn coalesced_upgrade_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "split_upgrade_frames")
fn split_upgrade_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "empty_text_control_frames")
fn empty_text_control_frames() -> Result(List(String), Nil)

@external(erlang, "beryl_ewe_transport_test_ffi", "empty_binary_frames")
fn empty_binary_frames() -> Result(List(BitArray), Nil)

pub fn rejects_101_in_headers_of_a_forbidden_response_test() -> Nil {
  assert_forbidden_upgrade(connect_websocket)
  assert_forbidden_upgrade(fn(port, path) {
    connect_websocket_with_origin(port, path, "https://example.test")
  })
}

fn assert_forbidden_upgrade(
  connect: fn(Int, String) -> Result(socket.Socket, Nil),
) -> Nil {
  let assert Ok(listener) =
    tcp.listen(0, [options.Ip(options.Loopback), options.SendTimeout(1000)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  let finished = process.new_subject()
  let server =
    process.spawn_unlinked(fn() {
      process.send(finished, serve_forbidden_upgrade(listener))
    })
  let monitor = process.monitor(server)
  let rejected = case connect(port, "/socket") {
    Error(Nil) -> True
    Ok(connection) -> {
      // Also clean up the success socket when testing the buggy client.
      close_websocket(connection)
      False
    }
  }
  let listener_closed = tcp.close(listener)
  let server_result = process.receive(finished, 2000)
  // Bound cleanup even if the server failed or never reported completion.
  process.kill(server)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  // A completion racing with the timeout must not escape into another test.
  let late_completion = process.receive(finished, 0)

  listener_closed |> should.equal(Ok(Nil))
  stopped |> should.be_ok
  late_completion |> should.equal(Error(Nil))
  rejected |> should.be_true
  // The peer must observe the client close, not just a rejected result.
  server_result |> should.equal(Ok(Ok(Nil)))
}

fn serve_forbidden_upgrade(
  listener: socket.ListenSocket,
) -> Result(Nil, socket.SocketReason) {
  use connection <- result.try(tcp.accept_timeout(listener, 1000))
  let served = send_forbidden_response(connection)
  let closed = tcp.close(connection)
  use _ <- result.try(closed)
  served
}

fn send_forbidden_response(
  connection: socket.Socket,
) -> Result(Nil, socket.SocketReason) {
  use _ <- result.try(receive_upgrade_request(connection, "", 8))
  use _ <- result.try(tcp.send(
    connection,
    bytes_tree.from_string(
      "HTTP/1.1 403 Forbidden\r\nX-Diagnostic: 101 fake\r\nContent-Length: 0\r\n\r\n",
    ),
  ))
  case tcp.receive_timeout(connection, 0, 1000) {
    Error(socket.Closed) -> Ok(Nil)
    Error(reason) -> Error(reason)
    Ok(_) -> Error(socket.Badarg)
  }
}

fn receive_upgrade_request(
  connection: socket.Socket,
  request: String,
  remaining_chunks: Int,
) -> Result(Nil, socket.SocketReason) {
  case string.contains(request, "\r\n\r\n"), remaining_chunks > 0 {
    True, _ -> Ok(Nil)
    False, False -> Error(socket.Timeout)
    False, True -> {
      use chunk <- result.try(tcp.receive_timeout(connection, 0, 1000))
      use text <- result.try(
        bit_array.to_string(chunk) |> result.replace_error(socket.Badarg),
      )
      receive_upgrade_request(connection, request <> text, remaining_chunks - 1)
    }
  }
}

pub fn preserves_multiple_frames_coalesced_with_upgrade_test() -> Nil {
  coalesced_upgrade_frames()
  |> should.equal(Ok(["first", "second"]))
}

pub fn preserves_partial_frame_after_split_upgrade_headers_test() -> Nil {
  split_upgrade_frames()
  |> should.equal(Ok(["third", "fourth"]))
}

pub fn reads_empty_text_and_control_payloads_test() -> Nil {
  empty_text_control_frames()
  |> should.equal(Ok(["", "", "next"]))
}

pub fn reads_empty_binary_payload_and_following_frame_test() -> Nil {
  empty_binary_frames()
  |> should.equal(Ok([<<>>, <<"next":utf8>>]))
}

pub fn close_waits_for_peer_tcp_close_with_a_bounded_deadline_test() -> Nil {
  assert_graceful_close(False)
  assert_graceful_close(True)
}

fn assert_graceful_close(keep_sending: Bool) -> Nil {
  let assert Ok(listener) =
    tcp.listen(0, [options.Ip(options.Loopback), options.SendTimeout(1000)])
  let assert Ok(#(_, port)) = tcp.sockname(listener)
  let finished = process.new_subject()
  let server =
    process.spawn_unlinked(fn() {
      process.send(finished, serve_delayed_close(listener, keep_sending))
    })
  let monitor = process.monitor(server)
  let assert Ok(connection) = connect_websocket(port, "/socket")
  let closed = close_websocket(connection)
  // Check local cleanup while the client owner is still alive.
  let local_receive = tcp.receive_timeout(connection, 0, 0)
  let listener_closed = tcp.close(listener)
  let server_result = process.receive(finished, 3000)
  process.kill(server)
  let stopped =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)
  process.demonitor_process(monitor)
  let late_completion = process.receive(finished, 0)

  closed |> should.equal(Nil)
  local_receive |> should.equal(Error(socket.Closed))
  listener_closed |> should.equal(Ok(Nil))
  stopped |> should.be_ok
  late_completion |> should.equal(Error(Nil))
  server_result |> should.equal(Ok(Ok(Nil)))
}

fn serve_delayed_close(
  listener: socket.ListenSocket,
  keep_sending: Bool,
) -> Result(Nil, socket.SocketReason) {
  use connection <- result.try(tcp.accept_timeout(listener, 1000))
  let served = exchange_delayed_close(connection, keep_sending)
  let closed = tcp.close(connection)
  use _ <- result.try(closed)
  served
}

fn exchange_delayed_close(
  connection: socket.Socket,
  keep_sending: Bool,
) -> Result(Nil, socket.SocketReason) {
  use _ <- result.try(receive_upgrade_request(connection, "", 8))
  use _ <- result.try(tcp.send(
    connection,
    bytes_tree.from_string(
      "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n\r\n",
    ),
  ))
  use frame <- result.try(tcp.receive_timeout(connection, 6, 1000))
  case frame {
    <<0x88, 0x80, 0, 0, 0, 0>> -> {
      // A timeout, rather than EOF, proves TCP stays open while the peer
      // delays its Close response. This fails with the old immediate close.
      use _ <- result.try(expect_open_connection(connection))
      case keep_sending {
        True -> send_until_client_deadline(connection, 20)
        False -> {
          use _ <- result.try(tcp.send(
            connection,
            bytes_tree.from_bit_array(<<0x81, 1, 120, 0x88, 0>>),
          ))
          // Even receiving the server's Close must not pre-empt its TCP close.
          expect_open_connection(connection)
        }
      }
    }
    _ -> Error(socket.Badarg)
  }
}

fn expect_open_connection(
  connection: socket.Socket,
) -> Result(Nil, socket.SocketReason) {
  case tcp.receive_timeout(connection, 0, 100) {
    Error(socket.Timeout) -> Ok(Nil)
    Error(reason) -> Error(reason)
    Ok(_) -> Error(socket.Badarg)
  }
}

fn send_until_client_deadline(
  connection: socket.Socket,
  remaining: Int,
) -> Result(Nil, socket.SocketReason) {
  case remaining {
    0 -> Error(socket.Timeout)
    _ -> {
      // A broken per-receive timeout would keep waiting for all 20 chunks.
      let received =
        tcp.send(connection, bytes_tree.from_bit_array(<<0x81, 1, 120>>))
        |> result.try(fn(_) { tcp.receive_timeout(connection, 0, 100) })
      // Closure can race with either send or receive at the deadline.
      case received {
        Error(socket.Closed) -> Ok(Nil)
        Error(socket.Timeout) ->
          send_until_client_deadline(connection, remaining - 1)
        Error(reason) -> Error(reason)
        Ok(_) -> Error(socket.Badarg)
      }
    }
  }
}
