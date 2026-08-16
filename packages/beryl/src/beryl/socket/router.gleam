//// Topic-namespace routing for a hand-written `update` function.
////
//// Most applications should use the `beryl_channels` package instead, which
//// owns the entry point, keeps each channel's state and server-side message
//// type private, and needs no hand-written dispatch. This module is the
//// escape hatch for apps that want `beryl.child_spec` and their own `update`
//// with no additional dependency.
////
//// An app built with `beryl.child_spec` receives every wire input for a
//// socket in one `update` function. This module decides which topic
//// namespace owns an input and hands it to that namespace's
//// `join`/`message`/`closed` handlers.
////
//// Namespaces are keyed on `beryl/topic` patterns — the same pattern
//// language used by `beryl.with_topic_rate` — and the values captured by a
//// pattern's wildcards are delivered to handlers in `Match`, so apps never
//// re-split topic strings by hand.
////
//// Each `Namespace` callback takes and returns the whole socket-wide model,
//// so every namespace on a socket shares one model type and the app owns
//// how per-topic state is stored in it.
////
//// Routing fails closed: a `Join` for a topic no namespace claims is
//// rejected, while other inputs for unclaimed topics are ignored.

import beryl/socket.{
  type Effect, type Input, type Next, type Ref, type StopReason,
}
import beryl/topic.{type TopicPattern}
import gleam/dynamic.{type Dynamic}
import gleam/json.{type Json}
import gleam/list
import gleam/option.{type Option, None}
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
/// Build with `namespace` (the app stores whatever per-topic state it needs
/// in its own model) or `accept_only` (no state at all). Opaque so
/// namespaces can gain new capabilities without breaking existing code.
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

/// The conventional rejection payload for a topic no namespace claims.
pub fn unknown_topic() -> Json {
  json.object([#("reason", json.string("unknown_topic"))])
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
