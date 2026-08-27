//// Collaborative-document channel logic.
////
//// Each `document:<tenant>:<document>` join gets private state. Join-level
//// tenant-token auth requires a `token` HMAC-signed for the topic's tenant.

import beryl/channel
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import example_helpers/payload
import gleam/dynamic.{type Dynamic}
import gleam/io
import gleam/json
import gleam/result
import gleam/string

/// Maximum byte size of a `sync_state` payload's `state` field.
const max_state_bytes = 65_536

/// Private state for one joined document.
pub type Model {
  Model(document_key: String)
}

/// Dependencies the document channel needs.
pub type Ctx {
  Ctx(store: Store, secret: BitArray)
}

/// Build a collision-resistant key for a tenant/document pair.
pub fn build_document_key(tenant: String, document: String) -> String {
  json.array([tenant, document], json.string)
  |> json.to_string
}

/// Build the collaborative-document channel.
pub fn handler(ctx: Ctx) -> channel.Handler {
  channel.handler("document:*", fn(context) {
    case authorize_join(ctx, context.params, context.payload) {
      Error(reason) -> channel.reject(reason)
      Ok(#(model, reply)) ->
        channel.accept(model)
        |> channel.on_message(fn(model, message) {
          case message.event {
            "sync_state" -> sync_state(ctx, model, message)
            _ ->
              channel.next(model, [
                channel.reply_ok(message.reply, error_payload("unknown_event")),
              ])
          }
        })
        |> channel.with_reply(reply)
    }
  })
}

/// Validate one document join and return its initial state and reply.
///
/// The handler claims the whole `document:` prefix so malformed document
/// topics receive the same `invalid_topic` reason as any other unowned topic.
pub fn authorize_join(
  ctx: Ctx,
  params: List(String),
  raw: Dynamic,
) -> Result(#(Model, json.Json), json.Json) {
  case params {
    [suffix] ->
      case string.split(suffix, ":") {
        [tenant, document] -> authorize_tenant(ctx, tenant, document, raw)
        _ -> Error(error_payload("invalid_topic"))
      }
    _ -> Error(error_payload("invalid_topic"))
  }
}

fn authorize_tenant(
  ctx: Ctx,
  tenant: String,
  document: String,
  raw: Dynamic,
) -> Result(#(Model, json.Json), json.Json) {
  use token <- result.try(
    payload.string_field(raw, "token")
    |> result.map_error(fn(_) { error_payload("missing_token") }),
  )
  use _ <- result.try(
    auth.verify_tenant(token, tenant, ctx.secret)
    |> result.map_error(fn(_) { error_payload("unauthorized") }),
  )

  let document_key = build_document_key(tenant, document)
  Ok(#(
    Model(document_key: document_key),
    json.object([
      #("tenant", json.string(tenant)),
      #("document", json.string(document)),
      #("state", stored_state(ctx, document_key)),
    ]),
  ))
}

fn sync_state(
  ctx: Ctx,
  model: Model,
  message: channel.Message,
) -> channel.Next(Model) {
  case payload.string_field(message.payload, "state") {
    Error(_) ->
      channel.next(model, [
        channel.reply_ok(message.reply, error_payload("invalid_state")),
      ])
    Ok(state) ->
      case string.byte_size(state) > max_state_bytes {
        True ->
          channel.next(model, [
            channel.reply_ok(message.reply, error_payload("state_too_large")),
          ])
        False -> {
          doc_store.merge_state(ctx.store, model.document_key, state)
          channel.next(model, [
            channel.broadcast_from(
              "doc_state",
              json.object([#("state", json.string(state))]),
            ),
          ])
        }
      }
  }
}

fn stored_state(ctx: Ctx, document_key: String) -> json.Json {
  case doc_store.get_state(ctx.store, document_key) {
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
}

fn error_payload(code: String) -> json.Json {
  json.object([#("code", json.string(code))])
}
