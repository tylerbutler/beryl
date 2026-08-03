//// Topic-namespace routing shared by the example apps.
////
//// Every example dispatches the same way: decide which topic namespace owns
//// an input, hand it to that namespace's `join`/`update`/`closed` surface,
//// and store the returned per-topic state back into the socket-wide model.
//// The standalone servers and the composing showcase app differ only in
//// which namespaces they register, so the dispatch itself lives here.
////
//// Each `Namespace` callback takes and returns the whole socket-wide model,
//// which is what lets namespaces with different per-topic state types share
//// one list.

import beryl/socket.{
  type ConnectInfo, type Effect, type Input, type Next, type Ref,
}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}

/// One topic namespace's handlers, adapted to the app's socket-wide model.
pub type Namespace(model) {
  Namespace(
    /// Whether this namespace owns a topic. The first match wins.
    matches: fn(String) -> Bool,
    join: fn(model, String, Dynamic, Ref) -> #(model, List(Effect)),
    message: fn(model, String, String, Dynamic, Option(Ref)) ->
      #(model, List(Effect)),
    closed: fn(model, String) -> #(model, List(Effect)),
  )
}

/// A namespace that accepts joins and ignores everything else — for
/// read-only topics carrying no per-socket state.
pub fn accept_only(topic: String) -> Namespace(model) {
  Namespace(
    matches: fn(candidate) { candidate == topic },
    join: fn(model, _topic, _payload, ref) {
      #(model, [socket.AcceptJoin(ref, None)])
    },
    message: fn(model, _topic, _event, _payload, _ref) { #(model, []) },
    closed: fn(model, _topic) { #(model, []) },
  )
}

/// Adapt handlers whose per-topic state lives in a `Dict` inside the
/// socket-wide model.
pub fn stateful(
  matches matches: fn(String) -> Bool,
  socket_id socket_id: fn(model) -> String,
  get get: fn(model) -> Dict(String, sub),
  put put: fn(model, Dict(String, sub)) -> model,
  join join: fn(String, String, Dynamic, Ref) -> #(Option(sub), List(Effect)),
  message message: fn(String, String, sub, String, Dynamic, Option(Ref)) ->
    #(sub, List(Effect)),
  closed closed: fn(String, String, sub) -> List(Effect),
) -> Namespace(model) {
  Namespace(
    matches:,
    join: fn(model, topic, payload, ref) {
      case join(socket_id(model), topic, payload, ref) {
        #(Some(sub), effects) -> #(
          put(model, dict.insert(get(model), topic, sub)),
          effects,
        )
        #(None, effects) -> #(model, effects)
      }
    },
    message: fn(model, topic, event, payload, ref) {
      case dict.get(get(model), topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            message(socket_id(model), topic, sub, event, payload, ref)
          #(put(model, dict.insert(get(model), topic, sub)), effects)
        }
        Error(Nil) -> #(model, [])
      }
    },
    closed: fn(model, topic) {
      case dict.get(get(model), topic) {
        Ok(sub) -> #(
          put(model, dict.delete(get(model), topic)),
          closed(socket_id(model), topic, sub),
        )
        Error(Nil) -> #(model, [])
      }
    },
  )
}

/// The conventional rejection payload for a topic no namespace claims.
pub fn unknown_topic() -> Json {
  json.object([#("reason", json.string("unknown_topic"))])
}

/// Canonical socket-wide model for a standalone stateful namespace.
pub type Standalone(sub) {
  Standalone(socket_id: String, topics: Dict(String, sub))
}

/// Initialize an empty standalone namespace model.
pub fn standalone_init(
  info: ConnectInfo(msg),
) -> #(Standalone(sub), List(Effect)) {
  #(Standalone(socket_id: info.socket_id, topics: dict.new()), [])
}

/// Project a namespace factory onto the canonical standalone model.
pub fn standalone_namespace(
  factory: fn(
    fn(Standalone(sub)) -> String,
    fn(Standalone(sub)) -> Dict(String, sub),
    fn(Standalone(sub), Dict(String, sub)) -> Standalone(sub),
  ) -> Namespace(Standalone(sub)),
) -> Namespace(Standalone(sub)) {
  factory(
    fn(model) { model.socket_id },
    fn(model) { model.topics },
    fn(model, topics) { Standalone(..model, topics: topics) },
  )
}

/// Route one input to the namespace that owns its topic.
///
/// Joins for a topic no namespace claims are rejected with
/// `reject_unknown`, so an app fails closed; other inputs for unclaimed
/// topics are ignored.
pub fn route(
  namespaces: List(Namespace(model)),
  reject_unknown: Json,
  model: model,
  ev: Input(msg),
) -> Next(model, msg) {
  case ev {
    socket.Join(topic, payload, ref) ->
      case owner(namespaces, topic) {
        Ok(ns) -> continue(ns.join(model, topic, payload, ref))
        Error(Nil) ->
          socket.Next(model, [socket.RejectJoin(ref, reject_unknown)])
      }

    socket.Message(topic, event, payload, ref) ->
      case owner(namespaces, topic) {
        Ok(ns) -> continue(ns.message(model, topic, event, payload, ref))
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Closed(topic, _reason) ->
      case owner(namespaces, topic) {
        Ok(ns) -> continue(ns.closed(model, topic))
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Binary(_, _) | socket.Info(_) -> socket.Next(model, [])
  }
}

fn owner(
  namespaces: List(Namespace(model)),
  topic: String,
) -> Result(Namespace(model), Nil) {
  list.find(namespaces, fn(ns) { ns.matches(topic) })
}

fn continue(result: #(model, List(Effect))) -> Next(model, msg) {
  let #(model, effects) = result
  socket.Next(model, effects)
}
