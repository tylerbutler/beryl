//// Single-use atomic capabilities shared by socket admission and connection
//// reservations.

import gleam/erlang/process
import rasa/atomic

const pending_state = 0

const claimed_state = 1

const cancelled_state = 2

pub opaque type Token {
  Token(state: atomic.Atomic, owner: process.Pid)
}

/// Create a pending token owned by the calling process.
pub fn new() -> Token {
  Token(state: atomic.new(), owner: process.self())
}

/// Return the process that created the token.
pub fn owner(token: Token) -> process.Pid {
  token.owner
}

/// Cancel a pending token.
pub fn cancel(token: Token) -> Bool {
  atomic.compare_exchange(token.state, pending_state, cancelled_state)
  == Ok(Nil)
}

/// Claim a pending token while its creator is alive.
pub fn claim_if_owner_alive(token: Token) -> Bool {
  process.is_alive(token.owner)
  && atomic.compare_exchange(token.state, pending_state, claimed_state)
  == Ok(Nil)
}

/// Check that a token is pending and its creator is alive.
pub fn pending_if_owner_alive(token: Token) -> Bool {
  process.is_alive(token.owner) && pending(token)
}

/// Check whether a token is pending without checking its creator.
pub fn pending(token: Token) -> Bool {
  atomic.get(token.state) == pending_state
}
