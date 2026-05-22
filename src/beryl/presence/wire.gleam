//// Phoenix-compatible wire encoding for presence diffs.

import beryl/presence.{type Diff, type PresenceEntry, diff_joins, diff_leaves}
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
    #("joins", encode_entries(diff_joins(diff, topic))),
    #("leaves", encode_entries(diff_leaves(diff, topic))),
  ])
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
