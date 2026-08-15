//// Ref-gated reply effects shared by the example apps.

import beryl/socket.{type Effect, type Ref}
import gleam/json
import gleam/option.{type Option, None, Some}

/// Send an ok-status reply when the client supplied a ref; refless inputs
/// get no reply, matching the legacy behavior.
pub fn ok(ref: Option(Ref), payload: json.Json) -> List(Effect) {
  case ref {
    Some(ref) -> [socket.ReplyOk(ref, payload)]
    None -> []
  }
}
