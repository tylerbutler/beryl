import gleam/list

const max_entries = 100

pub type Entry {
  Entry(sequence: Int, event: String, payload: String)
}

/// Prepends an entry to the transcript, keeping at most 100 entries (newest first).
pub fn add(entries: List(Entry), entry: Entry) -> List(Entry) {
  [entry, ..entries]
  |> list.take(max_entries)
}
