import gleam/dict.{type Dict}
import gleam/erlang/process.{type Subject}
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

pub fn start() -> Result(Store, actor.StartError) {
  actor.new(State(docs: dict.new()))
  |> actor.on_message(handle_message)
  |> actor.start
  |> result.map(fn(started) { Store(subject: started.data) })
}

pub fn get_state(store: Store, key: String) -> Result(String, Nil) {
  let reply = process.new_subject()
  process.send(store.subject, GetState(key: key, reply: reply))

  case process.receive(from: reply, within: receive_timeout_ms) {
    Ok(result) -> result
    Error(_) -> Error(Nil)
  }
}

pub fn merge_state(store: Store, key: String, encoded: String) -> Nil {
  process.send(store.subject, MergeState(key: key, encoded: encoded))
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    GetState(key, reply) -> {
      let response = case dict.get(state.docs, key) {
        Ok(doc) -> Ok(doc |> or_map.to_json |> json.to_string)
        Error(_) -> Error(Nil)
      }
      process.send(reply, response)
      actor.continue(state)
    }

    MergeState(key, encoded) -> {
      let docs = case or_map.from_json(encoded) {
        Error(_) -> state.docs
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
        Error(_) -> docs
      }
  }
}
