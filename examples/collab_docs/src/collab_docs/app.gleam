//// Collaborative-document logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `document:*:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `Standalone` model plus `standalone_init`/
////   `standalone_update` wrappers that drive the standalone collab-docs
////   server through `beryl.child_spec`, reusing the same per-topic surface.
////
//// Join-level tenant-token auth is preserved: the join payload must carry a
//// `token` HMAC-signed for the tenant whose document is being joined.

import beryl/event.{type Effect, type Ref}
import beryl/topic as beryl_topic
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// Maximum byte size of a `sync_state` payload's `state` field. Protects
/// the doc_store actor from unbounded merges.
const max_state_bytes = 65_536

/// Topic pattern for document channels: `document:<tenant>:<document>`.
const document_topic_pattern_string = "document:*:*"

/// Per-topic state for one socket on a document.
pub type Model {
  Model(document_key: String)
}

/// Dependencies the document logic needs: the doc store and the shared
/// HMAC secret for tenant token verification.
pub type Ctx {
  Ctx(store: Store, secret: BitArray)
}

/// Build a collision-resistant key for a tenant/document pair.
pub fn build_document_key(tenant: String, document: String) -> String {
  json.array([tenant, document], json.string)
  |> json.to_string
}

/// Handle a join for a `document:*:*` topic. Returns `None` when rejected.
pub fn join(
  ctx: Ctx,
  _socket_id: String,
  topic_name: String,
  payload: Dynamic,
  ref: Ref,
) -> #(Option(Model), List(Effect)) {
  let pattern = beryl_topic.parse_pattern(document_topic_pattern_string)
  case beryl_topic.extract_wildcards(pattern, topic_name) {
    Ok([tenant, document]) ->
      // Channel-level auth: the join payload must carry a `token`
      // HMAC-signed for the tenant whose document is being joined.
      case extract_token(payload) {
        Error(_) -> #(None, [
          event.RejectJoin(ref, error_payload("missing_token")),
        ])
        Ok(token) ->
          case auth.verify_tenant(token, tenant, ctx.secret) {
            Error(_) -> #(None, [
              event.RejectJoin(ref, error_payload("unauthorized")),
            ])
            Ok(Nil) -> {
              let document_key = build_document_key(tenant, document)
              let state = case doc_store.get_state(ctx.store, document_key) {
                Ok(encoded) -> json.string(encoded)
                Error(doc_store.NotFound) -> json.null()
                Error(doc_store.Timeout) -> {
                  io.println_error(
                    "[collab_docs.app] doc_store.get_state timed out for key="
                    <> document_key,
                  )
                  json.null()
                }
              }
              let reply =
                json.object([
                  #("tenant", json.string(tenant)),
                  #("document", json.string(document)),
                  #("state", state),
                ])
              #(Some(Model(document_key: document_key)), [
                event.AcceptJoin(ref, Some(reply)),
              ])
            }
          }
      }

    _ -> #(None, [event.RejectJoin(ref, error_payload("invalid_topic"))])
  }
}

/// Handle a client message on a joined document topic.
pub fn update(
  ctx: Ctx,
  _socket_id: String,
  topic_name: String,
  model: Model,
  event_name: String,
  payload: Dynamic,
  ref: Option(Ref),
) -> #(Model, List(Effect)) {
  case event_name {
    "sync_state" -> sync_state(ctx, topic_name, model, payload, ref)
    _ -> #(model, reply_error("unknown_event", ref))
  }
}

/// Handle the topic closing. Documents keep no per-socket server state
/// beyond the model itself, so there is nothing to clean up.
pub fn closed(
  _ctx: Ctx,
  _socket_id: String,
  _topic_name: String,
  _model: Model,
) -> List(Effect) {
  []
}

// --- Standalone app-side dispatch wrapper ---

/// Socket-wide state for the standalone collab-docs server: one per-topic
/// `Model` per joined `document:*:*` topic, keyed by topic.
pub type Standalone {
  Standalone(socket_id: String, docs: Dict(String, Model))
}

/// `init` for the standalone collab-docs `beryl.child_spec` runtime.
pub fn standalone_init(
  info: event.ConnectInfo(Nil),
) -> #(Standalone, List(Effect)) {
  #(Standalone(socket_id: info.socket_id, docs: dict.new()), [])
}

/// `update` for the standalone collab-docs `beryl.child_spec` runtime: route
/// each event to the embeddable `join`/`update`/`closed` surface, keyed by
/// topic. Non-`document:*` joins are rejected (fail closed), mirroring the
/// old `document:*:*` handler registration.
pub fn standalone_update(
  ctx: Ctx,
  model: Standalone,
  ev: event.Event(Nil),
) -> event.Next(Standalone, Nil) {
  case ev {
    event.Join(topic, payload, ref) ->
      case topic {
        "document:" <> _ -> {
          let #(joined, effects) =
            join(ctx, model.socket_id, topic, payload, ref)
          case joined {
            Some(sub) ->
              event.Next(
                Standalone(..model, docs: dict.insert(model.docs, topic, sub)),
                effects,
              )
            None -> event.Next(model, effects)
          }
        }
        _ ->
          event.Next(model, [
            event.RejectJoin(ref, error_payload("invalid_topic")),
          ])
      }

    event.Message(topic, event_name, payload, ref) ->
      case dict.get(model.docs, topic) {
        Ok(sub) -> {
          let #(sub, effects) =
            update(ctx, model.socket_id, topic, sub, event_name, payload, ref)
          event.Next(
            Standalone(..model, docs: dict.insert(model.docs, topic, sub)),
            effects,
          )
        }
        Error(Nil) -> event.Next(model, [])
      }

    event.Closed(topic, _reason) ->
      case dict.get(model.docs, topic) {
        Ok(sub) ->
          event.Next(
            Standalone(..model, docs: dict.delete(model.docs, topic)),
            closed(ctx, model.socket_id, topic, sub),
          )
        Error(Nil) -> event.Next(model, [])
      }

    event.Binary(_, _) | event.Info(_) -> event.Next(model, [])
  }
}

fn sync_state(
  ctx: Ctx,
  topic_name: String,
  model: Model,
  payload: Dynamic,
  ref: Option(Ref),
) -> #(Model, List(Effect)) {
  case extract_state(payload) {
    Ok(state) ->
      case string.byte_size(state) > max_state_bytes {
        True -> #(model, reply_error("state_too_large", ref))
        False -> {
          doc_store.merge_state(ctx.store, model.document_key, state)
          #(model, [
            event.BroadcastFrom(
              topic_name,
              "doc_state",
              json.object([#("state", json.string(state))]),
            ),
          ])
        }
      }

    Error(_) -> #(model, reply_error("invalid_state", ref))
  }
}

/// The channel-module API sent state errors as an ok-status reply with an
/// error payload (and dropped them without a ref); mirror that.
fn reply_error(code: String, ref: Option(Ref)) -> List(Effect) {
  case ref {
    Some(r) -> [event.ReplyOk(r, error_payload(code))]
    None -> []
  }
}

fn extract_token(payload: Dynamic) -> Result(String, Nil) {
  let decoder = {
    use token <- decode.field("token", decode.string)
    decode.success(token)
  }
  decode.run(payload, decoder)
  |> result.replace_error(Nil)
}

fn extract_state(payload: Dynamic) -> Result(String, Nil) {
  let decoder = {
    use state <- decode.field("state", decode.string)
    decode.success(state)
  }
  decode.run(payload, decoder)
  |> result.replace_error(Nil)
}

fn error_payload(code: String) -> json.Json {
  json.object([#("code", json.string(code))])
}
