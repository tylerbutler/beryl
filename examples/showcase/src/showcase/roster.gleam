//// The presence snapshot a channel broadcasts as one of its members leaves.
////
//// beryl untracks whatever presence a closing topic still holds and
//// broadcasts the matching `presence_diff` — but that happens *after* the
//// channel's `on_terminate` runs, and the example UIs render the
//// app-level `presence_list` snapshot rather than diffs. So a leaving
//// channel takes the snapshot itself and removes its own entry, which is
//// exactly the entry beryl is about to untrack.

import beryl/presence.{type Presence}
import example_helpers/presence as presence_helpers
import gleam/json.{type Json}
import gleam/list

/// The `presence_list` payload for `topic` with one socket's entry for
/// `key` removed.
pub fn without(
  presence: Presence,
  topic: String,
  socket_id: String,
  key: String,
) -> Json {
  presence.list(presence, topic)
  |> list.filter(fn(entry) {
    !{ entry.session_id == socket_id && entry.key == key }
  })
  |> presence_helpers.encode_users
}
