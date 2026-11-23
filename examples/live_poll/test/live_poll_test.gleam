import gleam/dynamic
import gleeunit/should
import live_poll/poll
import live_poll/store
import unitest

pub fn main() -> Nil {
  unitest.main()
}

pub fn votes_are_counted_and_closed_polls_reject_votes_test() -> Nil {
  let assert Ok(state) = poll.vote(poll.new(), poll.Gleam)
  let assert poll.Poll(gleam_votes: 1, erlang_votes: 0, status: poll.Open) =
    state
  let assert poll.ClosedNow(closed) = poll.close(state)
  poll.vote(closed, poll.Erlang) |> should.equal(Error(poll.PollClosed))
}

pub fn closing_is_idempotent_test() -> Nil {
  let assert poll.ClosedNow(closed) = poll.close(poll.new())
  let assert poll.AlreadyClosed(same) = poll.close(closed)
  same |> should.equal(closed)
}

pub fn protocol_commands_are_explicit_test() -> Nil {
  let vote_payload =
    dynamic.properties([
      #(dynamic.string("option"), dynamic.string("erlang")),
    ])
  poll.command("get_state", dynamic.properties([]))
  |> should.equal(poll.GetState)
  poll.command("vote", vote_payload) |> should.equal(poll.Vote(poll.Erlang))
  poll.command("vote", dynamic.properties([])) |> should.equal(poll.Unsupported)
}

pub fn typed_commands_report_unknown_events_and_invalid_choices_test() -> Nil {
  poll.decode_command("get_state", dynamic.nil())
  |> should.equal(Ok(poll.GetState))
  poll.decode_command("close_poll", dynamic.nil())
  |> should.equal(Ok(poll.Close))
  let payload =
    dynamic.properties([
      #(dynamic.string("option"), dynamic.string("gleam")),
    ])
  poll.decode_command("vote", payload)
  |> should.equal(Ok(poll.Vote(poll.Gleam)))
  poll.decode_command("vote", dynamic.nil())
  |> should.equal(Error(poll.InvalidChoice))
  poll.decode_command(
    "vote",
    dynamic.properties([
      #(dynamic.string("option"), dynamic.string("unknown")),
    ]),
  )
  |> should.equal(Error(poll.InvalidChoice))
  poll.decode_command("unknown", dynamic.nil())
  |> should.equal(Error(poll.UnknownEvent("unknown")))
}

pub fn empty_rooms_are_removed_test() -> Nil {
  let assert Ok(polls) = store.start()
  store.join(polls, "demo")
  let assert Ok(_) = store.vote(polls, "demo", poll.Gleam)
  store.leave(polls, "demo")
  store.join(polls, "demo")
  store.get(polls, "demo") |> should.equal(poll.new())
}

pub fn expiry_is_bound_to_the_shared_poll_generation_test() -> Nil {
  let assert Ok(polls) = store.start()
  let original = store.join(polls, "demo")
  store.join(polls, "demo") |> should.equal(original)
  let assert Ok(voted) = store.vote(polls, "demo", poll.Gleam)
  let assert poll.ClosedNow(closed) = poll.close(voted)
  store.expire(polls, "demo", original) |> should.equal(Ok(closed))
  store.expire(polls, "demo", original) |> should.equal(Error(Nil))

  store.leave(polls, "demo")
  store.expire(polls, "demo", original) |> should.equal(Error(Nil))
  let replacement = store.join(polls, "demo")
  should.be_false(replacement == original)
  store.expire(polls, "demo", original) |> should.equal(Error(Nil))
  store.get(polls, "demo") |> should.equal(poll.new())
  let assert poll.ClosedNow(closed) = poll.close(poll.new())
  store.expire(polls, "demo", replacement) |> should.equal(Ok(closed))
}

pub fn memberships_are_per_owner_and_room_test() -> Nil {
  let assert Ok(polls) = store.start()
  store.join(polls, "first")
  store.join(polls, "second")
  store.join(polls, "second")
  let assert Ok(voted) = store.vote(polls, "second", poll.Erlang)
  store.leave(polls, "first")
  store.leave(polls, "first")
  store.get(polls, "second") |> should.equal(voted)
  store.leave(polls, "second")
  store.close(polls, "second") |> should.equal(store.RoomNotFound)
}
