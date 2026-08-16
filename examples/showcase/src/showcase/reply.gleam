//// Ref-gated replies for the showcase channels.
////
//// A client event only gets a reply when it supplied a ref; refless
//// events are dropped, matching the example apps' raw-dispatch behavior
//// (`example_helpers/reply`).

import beryl/socket.{type ReplyRef}
import beryl_channels/channel.{type Actions}
import gleam/json.{type Json}
import gleam/option.{type Option, None, Some}

/// Add an ok-status reply when the client supplied a ref.
pub fn ok(actions: Actions, reply: Option(ReplyRef), payload: Json) -> Actions {
  case reply {
    Some(ref) -> channel.reply_ok(actions, ref, payload)
    None -> actions
  }
}
