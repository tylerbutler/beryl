//// Collaborative-document logic for app-side dispatch.
////
//// Two layers share one source of truth:
////
//// - A topic-scoped `Model`/`join`/`update`/`closed` surface that a
////   composing app (see the showcase example) routes `document:*:*` events
////   through, storing the returned model per topic.
//// - A socket-wide `Standalone` model plus `standalone_init`/
////   `standalone_update` wrappers that drive the standalone collab-docs
////   server through a `beryl.child_spec` runtime, reusing the same per-topic
////   surface.
////
//// Join-level tenant-token auth is preserved: the join payload must carry a
//// `token` HMAC-signed for the tenant whose document is being joined.

import beryl/socket.{type Effect, type Ref}
import beryl/socket/router
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import example_helpers/payload
import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/io
import gleam/json
import gleam/option.{type Option, None, Some}
import gleam/string

/// Maximum byte size of a `sync_state` payload's `state` field. Protects
/// the doc_store actor from unbounded merges.
const max_state_bytes = 65_536

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
/// `match.params` carries the tenant and document captured by the
/// pattern's wildcards.
pub fn join(
  ctx: Ctx,
  _socket_id: String,
  match: router.Match,
  payload: Dynamic,
  ref: Ref,
) -> #(Option(Model), List(Effect)) {
  case match.params {
    [tenant, document] ->
      // Topic-level auth: the join payload must carry a `token`
      // HMAC-signed for the tenant whose document is being joined.
      case payload.string_field(payload, "token") {
        Error(_) -> #(None, [
          socket.RejectJoin(ref, error_payload("missing_token")),
        ])
        Ok(token) ->
          case auth.verify_tenant(token, tenant, ctx.secret) {
            Error(_) -> #(None, [
              socket.RejectJoin(ref, error_payload("unauthorized")),
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
                socket.AcceptJoin(ref, Some(reply)),
              ])
            }
          }
      }

    _ -> #(None, [socket.RejectJoin(ref, error_payload("invalid_topic"))])
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

/// Adapt the `document:*` handlers to a containing socket-wide model.
pub fn namespace(
  ctx: Ctx,
  socket_id socket_id: fn(model) -> String,
  get get: fn(model) -> Dict(String, Model),
  put put: fn(model, Dict(String, Model)) -> model,
) -> router.Namespace(model) {
  router.stateful(
    pattern: "document:*:*",
    socket_id:,
    get:,
    put:,
    join: fn(socket_id, match, payload, ref) {
      join(ctx, socket_id, match, payload, ref)
    },
    message: fn(socket_id, match: router.Match, model, event_name, payload, ref) {
      update(ctx, socket_id, match.topic, model, event_name, payload, ref)
    },
    closed: fn(_socket_id, _match, _model) { [] },
  )
}

/// Build the standalone update once, sharing the canonical router model.
pub fn standalone_update(
  ctx: Ctx,
) -> fn(router.Standalone(Model), socket.Input(Nil)) ->
  socket.Next(router.Standalone(Model), Nil) {
  let namespaces = [
    router.standalone_namespace(fn(socket_id, get, put) {
      namespace(ctx, socket_id, get, put)
    }),
  ]
  fn(model, input) {
    router.route(namespaces, error_payload("invalid_topic"), model, input)
  }
}

fn sync_state(
  ctx: Ctx,
  topic_name: String,
  model: Model,
  payload: Dynamic,
  ref: Option(Ref),
) -> #(Model, List(Effect)) {
  case payload.string_field(payload, "state") {
    Ok(state) ->
      case string.byte_size(state) > max_state_bytes {
        True -> #(model, reply_error("state_too_large", ref))
        False -> {
          doc_store.merge_state(ctx.store, model.document_key, state)
          #(model, [
            socket.BroadcastFrom(
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
  socket.reply_ok(ref, error_payload(code))
}

fn error_payload(code: String) -> json.Json {
  json.object([#("code", json.string(code))])
}
