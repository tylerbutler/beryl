import beryl_site/presence/transcript
import gleam/int
import gleam/list
import gleeunit/should

pub fn transcript_keeps_newest_one_hundred_entries_test() {
  // int.range(1, 102, ...) iterates 1..101 inclusive (stops when current == 102)
  let entries =
    int.range(from: 1, to: 102, with: [], run: fn(acc, index) {
      transcript.add(acc, transcript.Entry(index, "event", "payload"))
    })

  list.length(entries) |> should.equal(100)
  let assert [newest, ..] = entries
  newest.sequence |> should.equal(101)
}
