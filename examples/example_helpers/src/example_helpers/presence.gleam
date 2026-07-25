//// Presence payload encoders shared by the example apps.

import beryl/presence.{type PresenceEntry}
import gleam/json
import gleam/list

/// Encode presence entries as the `presence_list` payload:
/// `{session_id: meta}`.
pub fn encode_users(entries: List(PresenceEntry)) -> json.Json {
  json.object(list.map(entries, fn(entry) { #(entry.session_id, entry.meta) }))
}
