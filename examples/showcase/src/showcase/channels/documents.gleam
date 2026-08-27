//// The `document:` channel: one joined collaborative document per topic.
////
//// The same behavior the standalone collab_docs server implements with
//// raw app-side dispatch (`collab_docs/app`), written as a
//// `beryl/channel` handler. Join-level tenant-token auth is preserved:
//// the join payload must carry a `token` HMAC-signed for the tenant whose
//// document is being joined.
////
//// It claims the whole `document:` prefix, like the router it replaced,
//// and answers a topic that is not `document:<tenant>:<document>` itself
//// with `invalid_topic`.

import beryl/channel
import collab_docs/app as docs_app
import collab_docs/auth
import collab_docs/doc_store.{type Store}
import example_helpers/payload
import gleam/io
import gleam/json.{type Json}
import gleam/string

/// Maximum byte size of a `sync_state` payload's `state` field. Protects
/// the doc_store actor from unbounded merges.
const max_state_bytes = 65_536

/// The pattern this channel is *registered* under: every `document:`
/// topic, not only well-formed three-segment ones.
///
/// The old app-side router claimed the whole `document:` prefix and
/// answered a wrong-shaped topic with `invalid_topic`. Registering the
/// narrower `document:*:*` here would instead leave those topics unowned
/// and answer `unmatched topic`, so the prefix is claimed here and the
/// segment check stays in the join callback, where it was.
const document_registration_pattern = "document:*"

/// Dependencies the document channel needs: the doc store and the shared
/// HMAC secret for tenant token verification.
pub type Ctx {
  Ctx(store: Store, secret: BitArray)
}

/// Private state of one joined document.
type State {
  State(document_key: String)
}

/// The `document:` channel.
pub fn channel(ctx: Ctx) -> channel.Handler {
  channel.handler(document_registration_pattern, fn(context) {
    case context.params {
      [suffix] ->
        case string.split(suffix, ":") {
          [tenant, document] ->
            case payload.string_field(context.payload, "token") {
              Error(_) -> channel.reject(error("missing_token"))

              Ok(token) ->
                case auth.verify_tenant(token, tenant, ctx.secret) {
                  Error(_) -> channel.reject(error("unauthorized"))
                  Ok(Nil) -> open(ctx, tenant, document)
                }
            }

          _ -> channel.reject(error("invalid_topic"))
        }

      _ -> channel.reject(error("invalid_topic"))
    }
  })
}

fn open(
  ctx: Ctx,
  tenant: String,
  document: String,
) -> channel.JoinResult(State, Nil) {
  let document_key = docs_app.build_document_key(tenant, document)

  channel.accept(State(document_key: document_key))
  |> channel.on_message(fn(state: State, message: channel.Message) {
    case message.event {
      "sync_state" ->
        case payload.string_field(message.payload, "state") {
          Error(_) ->
            channel.next(state, [
              channel.reply_ok(message.reply, error("invalid_state")),
            ])

          Ok(encoded) ->
            case string.byte_size(encoded) > max_state_bytes {
              True ->
                channel.next(state, [
                  channel.reply_ok(message.reply, error("state_too_large")),
                ])

              False -> {
                doc_store.merge_state(ctx.store, state.document_key, encoded)
                channel.next(state, [
                  channel.broadcast_from(
                    "doc_state",
                    json.object([#("state", json.string(encoded))]),
                  ),
                ])
              }
            }
        }

      _ ->
        channel.next(state, [
          channel.reply_ok(message.reply, error("unknown_event")),
        ])
    }
  })
  |> channel.with_reply(
    json.object([
      #("tenant", json.string(tenant)),
      #("document", json.string(document)),
      #("state", stored_state(ctx, document_key)),
    ]),
  )
}

fn stored_state(ctx: Ctx, document_key: String) -> Json {
  case doc_store.get_state(ctx.store, document_key) {
    Ok(encoded) -> json.string(encoded)
    Error(doc_store.NotFound) -> json.null()
    Error(doc_store.Timeout) -> {
      io.println_error(
        "[showcase.channels.documents] doc_store.get_state timed out for key="
        <> document_key,
      )
      json.null()
    }
  }
}

/// State errors are sent as an ok-status reply carrying an error payload,
/// matching the raw-dispatch app.
fn error(code: String) -> Json {
  json.object([#("code", json.string(code))])
}
