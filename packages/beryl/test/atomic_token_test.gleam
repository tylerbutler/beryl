import beryl/atomic_token
import gleam/erlang/process
import gleeunit/should

pub fn new_token_is_pending_test() -> Nil {
  let token = atomic_token.new()

  atomic_token.owner(token) |> should.equal(process.self())
  atomic_token.pending(token) |> should.be_true
  atomic_token.pending_if_owner_alive(token) |> should.be_true
}

pub fn token_can_only_be_claimed_once_test() -> Nil {
  let token = atomic_token.new()

  atomic_token.claim_if_owner_alive(token) |> should.be_true
  atomic_token.claim_if_owner_alive(token) |> should.be_false
  atomic_token.cancel(token) |> should.be_false
  atomic_token.pending(token) |> should.be_false
}

pub fn concurrent_claim_has_one_winner_test() -> Nil {
  let token = atomic_token.new()
  let claims = process.new_subject()

  process.spawn(fn() {
    process.send(claims, atomic_token.claim_if_owner_alive(token))
  })
  process.spawn(fn() {
    process.send(claims, atomic_token.claim_if_owner_alive(token))
  })

  let assert Ok(first) = process.receive(claims, 1000)
  let assert Ok(second) = process.receive(claims, 1000)
  let one_winner = first != second

  one_winner |> should.be_true
}

pub fn token_can_only_be_cancelled_once_test() -> Nil {
  let token = atomic_token.new()

  atomic_token.cancel(token) |> should.be_true
  atomic_token.cancel(token) |> should.be_false
  atomic_token.claim_if_owner_alive(token) |> should.be_false
  atomic_token.pending(token) |> should.be_false
}

pub fn dead_owner_only_invalidates_admission_pending_test() -> Nil {
  let tokens = process.new_subject()
  let owner = process.spawn(fn() { process.send(tokens, atomic_token.new()) })
  let monitor = process.monitor(owner)
  let assert Ok(token) = process.receive(tokens, 1000)
  let assert Ok(_) =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
    |> process.selector_receive(1000)

  atomic_token.owner(token) |> should.equal(owner)
  atomic_token.pending_if_owner_alive(token) |> should.be_false
  atomic_token.claim_if_owner_alive(token) |> should.be_false
  atomic_token.pending(token) |> should.be_true
}
