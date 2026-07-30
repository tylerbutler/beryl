import beryl/channel as beryl_channel
import beryl/socket
import collab_docs/channel
import gleam/json
import gleeunit/should

pub fn document_key_uses_json_array_encoding_test() {
  channel.build_document_key("tenant", "document")
  |> should.equal("[\"tenant\",\"document\"]")
}

pub fn document_key_distinguishes_slashes_in_wildcards_test() {
  channel.build_document_key("a/b", "c")
  |> should.not_equal(channel.build_document_key("a", "b/c"))
}

fn test_socket() -> socket.Socket(Nil) {
  let transport =
    socket.new_transport(
      send_text: fn(_) { Ok(Nil) },
      send_binary: fn(_) { Ok(Nil) },
      close: fn() { Ok(Nil) },
    )
  socket.new("socket-1", Nil, transport)
}

/// `channel.Reply` always encodes `"status": "ok"` regardless of its event
/// name, so it cannot signal failure. Only `ReplyError` reaches the client's
/// `push.receive("error", ...)` hook — which is the *only* reply hook the
/// collab_docs frontend registers for `sync_state` (see priv/static/app.js).
pub fn reply_error_uses_an_error_status_reply_test() {
  case channel.reply_error("state_too_large", test_socket()) {
    beryl_channel.ReplyError(..) -> True
    _ -> False
  }
  |> should.be_true
}

pub fn reply_error_carries_the_code_in_its_payload_test() {
  let assert beryl_channel.ReplyError(payload:, ..) =
    channel.reply_error("invalid_state", test_socket())

  payload
  |> json.to_string
  |> should.equal("{\"code\":\"invalid_state\"}")
}
