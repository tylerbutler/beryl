//// Phoenix-compatible wire encoding for presence diffs.

import beryl/presence.{type Diff, type PresenceEntry}
import gleam/dict.{type Dict}
import gleam/json
import gleam/list
import gleam/result

/// Encode a presence diff for one topic as a Phoenix-compatible payload.
///
/// The resulting JSON has `joins` and `leaves` maps keyed by presence key,
/// where each value contains the tracked metadata under `metas`.
///
/// ```json
/// {
///   "joins": { "user:1": { "metas": [{ "status": "online" }] } },
///   "leaves": { "user:2": { "metas": [{ "status": "offline" }] } }
/// }
/// ```
pub fn encode_diff(diff: Diff, topic: String) -> json.Json {
  json.object([
    #("joins", encode_entries(presence.diff_joins(diff, topic))),
    #("leaves", encode_entries(presence.diff_leaves(diff, topic))),
  ])
}

/// Encode a topic's full presence list as a Phoenix-compatible
/// `presence_state` payload.
///
/// The resulting JSON is a map keyed by presence key, where each value
/// contains the tracked metadata under `metas` — the same shape as one side
/// of a `presence_diff`:
///
/// ```json
/// { "user:1": { "metas": [{ "status": "online", "phx_ref": "..." }] } }
/// ```
///
/// Phoenix clients expect a `presence_state` event carrying this payload
/// after joining a presence-enabled topic (followed by incremental
/// `presence_diff` events). Build the entry list with `presence.list`.
pub fn encode_state(entries: List(PresenceEntry)) -> json.Json {
  encode_entries(entries)
}

fn encode_entries(entries: List(PresenceEntry)) -> json.Json {
  entries
  |> group_metas_by_key
  |> dict.to_list
  |> list.map(fn(entry) {
    let #(key, metas) = entry
    #(
      key,
      json.object([
        #("metas", json.preprocessed_array(list.reverse(metas))),
      ]),
    )
  })
  |> json.object
}

fn group_metas_by_key(
  entries: List(PresenceEntry),
) -> Dict(String, List(json.Json)) {
  list.fold(entries, dict.new(), fn(grouped, entry) {
    let existing =
      dict.get(grouped, entry.key)
      |> result.unwrap([])
    dict.insert(grouped, entry.key, [entry.meta, ..existing])
  })
}
