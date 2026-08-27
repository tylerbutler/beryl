import gleam/dynamic
import gleeunit
import gleeunit/should
import live_poll/poll
import live_poll/store

pub fn main() {
  gleeunit.main()
}

pub fn votes_are_counted_and_closed_polls_reject_votes_test() {
  let assert Ok(state) = poll.vote(poll.new(), poll.Gleam)
  let assert poll.Poll(gleam_votes: 1, erlang_votes: 0, status: poll.Open) =
    state
  let assert poll.ClosedNow(closed) = poll.close(state)
  poll.vote(closed, poll.Erlang) |> should.equal(Error(poll.PollClosed))
}

pub fn closing_is_idempotent_test() {
  let assert poll.ClosedNow(closed) = poll.close(poll.new())
  let assert poll.AlreadyClosed(same) = poll.close(closed)
  same |> should.equal(closed)
}

pub fn protocol_commands_are_explicit_test() {
  let vote_payload =
    dynamic.properties([
      #(dynamic.string("option"), dynamic.string("erlang")),
    ])
  poll.command("get_state", dynamic.properties([]))
  |> should.equal(poll.GetState)
  poll.command("vote", vote_payload) |> should.equal(poll.Vote(poll.Erlang))
  poll.command("vote", dynamic.properties([])) |> should.equal(poll.Unsupported)
}

pub fn empty_rooms_are_removed_test() {
  let assert Ok(polls) = store.start()
  store.join(polls, "demo")
  let assert Ok(_) = store.vote(polls, "demo", poll.Gleam)
  store.leave(polls, "demo")
  store.join(polls, "demo")
  store.get(polls, "demo") |> should.equal(poll.new())
}
