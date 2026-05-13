import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
import gleam/io
import gleam/json
import gleam/otp/actor
import gleam/result
import lattice_maps/or_map.{type ORMap}

const receive_timeout_ms = 1000

pub opaque type Store {
  Store(subject: Subject(Message))
}

type Message {
  GetState(key: String, reply: Subject(Result(String, Nil)))
  MergeState(key: String, encoded: String)
}

type State {
  State(docs: Dict(String, ORMap))
}

/// Failure modes for `get_state`.
///
/// - `NotFound`: the store has no entry for the key (a normal miss).
/// - `Timeout`: the store actor did not reply within `receive_timeout_ms`
///   — typically an availability incident worth surfacing.
pub type GetError {
  NotFound
  Timeout
}

/// Starts the document store actor.
///
/// Returns `Error(actor.StartError)` if the OTP actor fails to initialise.
pub fn start() -> Result(Store, actor.StartError) {
  actor.new(State(docs: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Store(subject: started.data) })
}

/// Gets the encoded document state for a key.
///
/// Distinguishes a normal miss (`NotFound`) from an actor receive timeout
/// (`Timeout`) so callers can alert/log the latter without conflating it
/// with the absence of the document.
pub fn get_state(store: Store, key: String) -> Result(String, GetError) {
  let reply = process.new_subject()
  process.send(store.subject, GetState(key: key, reply: reply))

  case process.receive(from: reply, within: receive_timeout_ms) {
    Ok(Ok(encoded)) -> Ok(encoded)
    Ok(Error(Nil)) -> Error(NotFound)
    Error(_) -> Error(Timeout)
  }
}

/// Sends an encoded document state to the store for merging.
///
/// This is fire-and-forget: the function returns after enqueueing the message
/// and does not wait for the merge to be processed. Store actors handle messages
/// sequentially, and ORMap merges are commutative and idempotent, so concurrent
/// merge order should converge to the same state. Callers should not assume this
/// merge has completed before an immediate `get_state` from another process.
pub fn merge_state(store: Store, key: String, encoded: String) -> Nil {
  process.send(store.subject, MergeState(key: key, encoded: encoded))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    GetState(key, reply) -> {
      let response =
        dict.get(state.docs, key)
        |> result.map(fn(doc) { doc |> or_map.to_json |> json.to_string })
      process.send(reply, response)
      actor.continue(state)
    }

    MergeState(key, encoded) -> {
      let docs = case or_map.from_json(encoded) {
        Error(_) -> {
          // Decode failure is silent at the wire level (callers don't await),
          // so surface it on stderr to aid debugging schema/version skew.
          io.println_error(
            "[collab_docs.doc_store] discarded MergeState for key="
            <> key
            <> " (or_map.from_json failed)",
          )
          state.docs
        }
        Ok(remote) -> merge_doc(state.docs, key, remote)
      }
      actor.continue(State(docs: docs))
    }
  }
}

fn merge_doc(
  docs: Dict(String, ORMap),
  key: String,
  remote: ORMap,
) -> Dict(String, ORMap) {
  case dict.get(docs, key) {
    Error(_) -> dict.insert(docs, key, remote)
    Ok(local) ->
      case or_map.merge(local, remote) {
        Ok(merged) -> dict.insert(docs, key, merged)
        Error(_) -> {
          // ORMap merges should be commutative — failure indicates a real
          // bug worth seeing rather than silently dropping remote edits.
          io.println_error(
            "[collab_docs.doc_store] or_map.merge failed for key="
            <> key
            <> "; remote edits discarded",
          )
          docs
        }
      }
  }
}
