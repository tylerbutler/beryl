//// Phoenix-compatible wire encoding for presence diffs.

import beryl/presence.{type Diff}
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
    #("joins", encode_topic_entries(diff.joins, topic)),
    #("leaves", encode_topic_entries(diff.leaves, topic)),
  ])
}

fn encode_topic_entries(
  entries_by_topic: Dict(String, List(#(String, String, json.Json))),
  topic: String,
) -> json.Json {
  case dict.get(entries_by_topic, topic) {
    Error(_) -> json.object([])
    Ok(entries) -> {
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
  }
}

fn group_metas_by_key(
  entries: List(#(String, String, json.Json)),
) -> Dict(String, List(json.Json)) {
  list.fold(entries, dict.new(), fn(grouped, entry) {
    let #(key, _pid, meta) = entry
    let existing =
      dict.get(grouped, key)
      |> result.unwrap([])
    dict.insert(grouped, key, [meta, ..existing])
  })
}
