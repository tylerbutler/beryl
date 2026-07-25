//// Ref-gated reply effects shared by the example apps.

import beryl/socket.{type Effect, type Ref}
import gleam/json
import gleam/option.{type Option, None, Some}

/// Send an ok-status reply when the client supplied a ref; refless events
/// get no reply, matching the channel-module behavior of dropping refless
/// replies.
pub fn ok(ref: Option(Ref), payload: json.Json) -> List(Effect) {
  case ref {
    Some(r) -> [socket.ReplyOk(r, payload)]
    None -> []
  }
}
