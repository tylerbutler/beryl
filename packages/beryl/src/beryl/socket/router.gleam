//// Topic-namespace routing for app-side dispatch.
////
//// An app built with `beryl.child_spec` receives every wire input for a socket in
//// one `update` function. This module supplies the conventional shape of
//// that function: decide which topic namespace owns an input, hand it to
//// that namespace's `join`/`message`/`closed` handlers, and store the
//// returned state back into the socket-wide model.
////
//// Namespaces are keyed on `beryl/topic` patterns — the same pattern
//// language used by `beryl.with_topic_rate` — and the values captured by a
//// pattern's wildcards are delivered to handlers in `Match`, so apps never
//// re-split topic strings by hand.
////
//// Each `Namespace` callback takes and returns the whole socket-wide model,
//// which is what lets namespaces with different per-topic state types share
//// one list. `stateful` builds that adaptation from three projections for
//// the common Dict-per-topic shape, and `Standalone` is the canonical
//// socket-wide model for a server built around a single namespace.
////
//// Routing fails closed: a `Join` for a topic no namespace claims is
//// rejected, while other inputs for unclaimed topics are ignored.

import beryl/socket.{
  type ConnectInfo, type Effect, type Input, type Next, type Ref,
  type StopReason,
}
import beryl/topic.{type TopicPattern}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result

/// A topic claimed by a namespace: the concrete topic plus the values
/// captured by the pattern's wildcards, in order. For `"room:*"` matching
/// `"room:lobby"`, `params` is `["lobby"]`; for `"document:*:*"` matching
/// `"document:acme:readme"`, it is `["acme", "readme"]`; exact patterns
/// capture nothing.
pub type Match {
  Match(topic: String, params: List(String))
}

/// One topic namespace's handlers, adapted to the app's socket-wide model.
///
/// Build with `namespace` (full control over the model), `stateful` (state
/// in a Dict keyed by topic), or `accept_only` (no state at all). Opaque so
/// namespaces can grow new capabilities without breaking existing code.
pub opaque type Namespace(model) {
  Namespace(
    pattern: TopicPattern,
    join: fn(model, Match, Dynamic, Ref) -> #(model, List(Effect)),
    message: fn(model, Match, String, Dynamic, Option(Ref)) ->
      #(model, List(Effect)),
    closed: fn(model, Match, StopReason) -> #(model, List(Effect)),
  )
}

/// Build a namespace from a topic pattern (`beryl/topic` syntax, e.g.
/// `"lobby"`, `"room:*"`, or `"document:*:*"`) and handlers over the
/// socket-wide model.
pub fn namespace(
  pattern pattern: String,
  join join: fn(model, Match, Dynamic, Ref) -> #(model, List(Effect)),
  message message: fn(model, Match, String, Dynamic, Option(Ref)) ->
    #(model, List(Effect)),
  closed closed: fn(model, Match, StopReason) -> #(model, List(Effect)),
) -> Namespace(model) {
  Namespace(pattern: topic.parse_pattern(pattern), join:, message:, closed:)
}

/// A namespace that accepts joins and ignores everything else — for
/// read-only topics carrying no per-socket state.
pub fn accept_only(pattern: String) -> Namespace(model) {
  namespace(
    pattern:,
    join: fn(model, _match, _payload, ref) {
      #(model, [socket.AcceptJoin(ref, None)])
    },
    message: fn(model, _match, _event, _payload, _ref) { #(model, []) },
    closed: fn(model, _match, _reason) { #(model, []) },
  )
}

/// A namespace whose per-topic state lives in a `Dict` keyed by topic
/// inside the socket-wide model. `socket_id`, `get`, and `put` project the
/// model onto the pieces the namespace owns; `join`/`message`/`closed` are
/// the per-topic handlers. A join's `Some(sub)` is committed only when the
/// first matching join answer in its effects is `AcceptJoin`; rejected or
/// unanswered joins leave no state behind.
pub fn stateful(
  pattern pattern: String,
  socket_id socket_id: fn(model) -> String,
  get get: fn(model) -> Dict(String, sub),
  put put: fn(model, Dict(String, sub)) -> model,
  join join: fn(String, Match, Dynamic, Ref) -> #(Option(sub), List(Effect)),
  message message: fn(String, Match, sub, String, Dynamic, Option(Ref)) ->
    #(sub, List(Effect)),
  closed closed: fn(String, Match, sub, StopReason) -> List(Effect),
) -> Namespace(model) {
  namespace(
    pattern:,
    join: fn(model, match, payload, ref) {
      let #(sub, effects) = join(socket_id(model), match, payload, ref)
      let next_model = case sub, join_answer(effects, ref) {
        Some(sub), Accepted ->
          put(model, dict.insert(get(model), match.topic, sub))
        _, _ -> model
      }
      #(next_model, effects)
    },
    message: fn(model, match, event, payload, ref) {
      case dict.get(get(model), match.topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            message(socket_id(model), match, sub, event, payload, ref)
          #(put(model, dict.insert(get(model), match.topic, sub)), effects)
        }
        Error(Nil) -> #(model, [])
      }
    },
    closed: fn(model, match, reason) {
      case dict.get(get(model), match.topic) {
        Ok(sub) -> #(
          put(model, dict.delete(get(model), match.topic)),
          closed(socket_id(model), match, sub, reason),
        )
        Error(Nil) -> #(model, [])
      }
    },
  )
}

type JoinAnswer {
  Accepted
  Rejected
  Unanswered
}

fn join_answer(effects: List(Effect), ref: Ref) -> JoinAnswer {
  case effects {
    [] -> Unanswered
    [socket.AcceptJoin(answered_ref, _), ..] if answered_ref == ref -> Accepted
    [socket.RejectJoin(answered_ref, _), ..] if answered_ref == ref -> Rejected
    [_, ..rest] -> join_answer(rest, ref)
  }
}

/// The conventional rejection payload for a topic no namespace claims.
pub fn unknown_topic() -> Json {
  json.object([#("reason", json.string("unknown_topic"))])
}

/// Socket-wide model for a standalone server built around one stateful
/// namespace: the socket id plus one per-topic sub-model per joined topic.
pub type Standalone(sub) {
  Standalone(socket_id: String, topics: Dict(String, sub))
}

/// `init` for a standalone `beryl.child_spec` runtime whose model is
/// `Standalone`.
pub fn standalone_init(
  info: ConnectInfo(msg),
) -> #(Standalone(sub), List(Effect)) {
  #(Standalone(socket_id: info.socket_id, topics: dict.new()), [])
}

/// Adapt a projection-taking namespace factory to the canonical
/// `Standalone` model: the factory receives the `socket_id`/`get`/`put`
/// projections `stateful` expects.
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
    fn(model, topics) { Standalone(..model, topics:) },
  )
}

/// Route one input to the first namespace whose pattern matches its topic.
///
/// Joins for a topic no namespace claims are rejected with
/// `reject_unknown`, so an app fails closed; other inputs for unclaimed
/// topics are ignored, and `Binary`/`Info` inputs pass through unchanged.
pub fn route(
  namespaces: List(Namespace(model)),
  reject_unknown: Json,
  model: model,
  input: Input(msg),
) -> Next(model, msg) {
  case input {
    socket.Join(topic_name, payload, ref) ->
      case owner(namespaces, topic_name) {
        Ok(#(ns, match)) -> continue(ns.join(model, match, payload, ref))
        Error(Nil) ->
          socket.Next(model, [socket.RejectJoin(ref, reject_unknown)])
      }

    socket.Message(topic_name, event, payload, ref) ->
      case owner(namespaces, topic_name) {
        Ok(#(ns, match)) ->
          continue(ns.message(model, match, event, payload, ref))
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Closed(topic_name, reason) ->
      case owner(namespaces, topic_name) {
        Ok(#(ns, match)) -> continue(ns.closed(model, match, reason))
        Error(Nil) -> socket.Next(model, [])
      }

    socket.Binary(_, _) | socket.Info(_) -> socket.Next(model, [])
  }
}

fn owner(
  namespaces: List(Namespace(model)),
  topic_name: String,
) -> Result(#(Namespace(model), Match), Nil) {
  list.find_map(namespaces, fn(ns) {
    case topic.matches(ns.pattern, topic_name) {
      True ->
        Ok(#(ns, Match(topic: topic_name, params: captured(ns, topic_name))))
      False -> Error(Nil)
    }
  })
}

/// A matched pattern's wildcard captures; exact patterns capture nothing.
fn captured(ns: Namespace(model), topic_name: String) -> List(String) {
  topic.extract_wildcards(ns.pattern, topic_name)
  |> result.unwrap([])
}

fn continue(result: #(model, List(Effect))) -> Next(model, msg) {
  let #(model, effects) = result
  socket.Next(model, effects)
}
