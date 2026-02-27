//// DocumentChannel - Fluid Framework protocol handler for beryl
////
//// Ports the Elixir DocumentChannel logic to Gleam. Handles:
//// - connect_document: JWT auth, session creation, client join
//// - submitOp: Operation submission with scope checking
//// - submitSignal: Signal relay (v1/v2 format normalization)
//// - noop: Client RSN updates
//// - requestOps: Delta catch-up

import beryl/channel
import beryl/coordinator.{
  type ChannelHandler, type HandleResultErased, type JoinResultErased,
  type SocketContext, ChannelHandler, JoinErrorErased, JoinOkErased,
  NoReplyErased,
}
import beryl/topic
import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/option.{None, Some}
import gleam/string

/// Channel state - pre-connect or post-connect
pub type DocumentAssigns {
  /// After topic join, before connect_document
  Pending(tenant_id: String, document_id: String)
  /// After successful connect_document
  Connected(
    tenant_id: String,
    document_id: String,
    client_id: String,
    mode: String,
    session_pid: Dynamic,
    claims: Dynamic,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// FFI declarations for Elixir interop
// ─────────────────────────────────────────────────────────────────────────────

@external(erlang, "levee_document_ffi", "jwt_verify")
fn jwt_verify(token: String, tenant_id: String) -> Dynamic

@external(erlang, "levee_document_ffi", "jwt_expired")
fn jwt_expired(claims: Dynamic) -> Bool

@external(erlang, "levee_document_ffi", "jwt_has_read_scope")
fn jwt_has_read_scope(claims: Dynamic) -> Bool

@external(erlang, "levee_document_ffi", "jwt_has_write_scope")
fn jwt_has_write_scope(claims: Dynamic) -> Bool

@external(erlang, "levee_document_ffi", "registry_get_or_create_session")
fn registry_get_or_create_session(
  tenant_id: String,
  document_id: String,
) -> Dynamic

@external(erlang, "levee_document_ffi", "session_client_join")
fn session_client_join(
  session_pid: Dynamic,
  connect_msg: Dynamic,
  handler_pid: Dynamic,
) -> Dynamic

@external(erlang, "levee_document_ffi", "session_submit_ops")
fn session_submit_ops(
  session_pid: Dynamic,
  client_id: String,
  batches: Dynamic,
) -> Dynamic

@external(erlang, "levee_document_ffi", "session_submit_signals")
fn session_submit_signals(
  session_pid: Dynamic,
  client_id: String,
  signals: Dynamic,
) -> Dynamic

@external(erlang, "levee_document_ffi", "session_update_client_rsn")
fn session_update_client_rsn(
  session_pid: Dynamic,
  client_id: String,
  rsn: Int,
) -> Dynamic

@external(erlang, "levee_document_ffi", "session_get_ops_since")
fn session_get_ops_since(session_pid: Dynamic, sn: Int) -> Dynamic

@external(erlang, "levee_document_ffi", "session_client_leave")
fn session_client_leave(session_pid: Dynamic, client_id: String) -> Dynamic

/// Notify the WebSocket handler about the session PID so it can monitor it
@external(erlang, "levee_document_ffi", "notify_handler_session")
fn notify_handler_session(handler_pid: Dynamic, session_pid: Dynamic) -> Dynamic

/// Unsafe coerce any value to Dynamic (uses beryl_ffi identity)
@external(erlang, "beryl_ffi", "identity")
fn to_dynamic(value: a) -> Dynamic

/// Unsafe coerce Dynamic to DocumentAssigns
@external(erlang, "beryl_ffi", "identity")
fn unsafe_coerce_assigns(value: Dynamic) -> DocumentAssigns

/// Encode a push with a Dynamic payload using Jason
@external(erlang, "levee_document_ffi_helpers", "dynamic_push")
fn dynamic_push(topic: String, event: String, payload: Dynamic) -> String

/// Create an Elixir map %{"clientId" => "", "nacks" => nacks}
@external(erlang, "levee_document_ffi_helpers", "make_nack_map")
fn make_nack_map(client_id: String, nacks: Dynamic) -> Dynamic

/// Create an Elixir map %{"documentId" => doc_id, "op" => ops}
@external(erlang, "levee_document_ffi_helpers", "make_op_map")
fn make_op_map(document_id: String, ops: Dynamic) -> Dynamic

/// Convert an Erlang atom to a binary string
@external(erlang, "erlang", "atom_to_binary")
fn atom_to_string(atom: Dynamic) -> String

// ─────────────────────────────────────────────────────────────────────────────
// Channel construction
// ─────────────────────────────────────────────────────────────────────────────

/// Create a new DocumentChannel handler for beryl registration.
///
/// Returns a ChannelHandler directly (not a typed Channel) because we need
/// Dynamic payloads for Elixir interop rather than Json.
pub fn new() -> ChannelHandler {
  ChannelHandler(
    pattern: topic.parse_pattern("document:*"),
    join: join,
    handle_in: handle_in,
    handle_binary: fn(_data, ctx) {
      coordinator.NoReplyErased(assigns: ctx.assigns)
    },
    terminate: terminate,
  )
}

// ─────────────────────────────────────────────────────────────────────────────
// Join handler
// ─────────────────────────────────────────────────────────────────────────────

fn join(
  topic_name: String,
  _payload: Dynamic,
  _ctx: SocketContext,
) -> JoinResultErased {
  // Parse "document:{tenant_id}:{document_id}" from topic
  case parse_topic(topic_name) {
    Ok(#(tenant_id, document_id)) -> {
      let assigns = Pending(tenant_id: tenant_id, document_id: document_id)
      JoinOkErased(reply: None, assigns: to_dynamic(assigns))
    }
    Error(_) -> {
      JoinErrorErased(
        reason: json.object([#("reason", json.string("invalid_topic"))]),
      )
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HandleIn handler - dispatches on event name
// ─────────────────────────────────────────────────────────────────────────────

fn handle_in(
  event: String,
  payload: Dynamic,
  ctx: SocketContext,
) -> HandleResultErased {
  let assigns = unsafe_coerce_assigns(ctx.assigns)

  case event {
    "connect_document" -> handle_connect_document(payload, ctx, assigns)
    "submitOp" -> handle_submit_op(payload, ctx, assigns)
    "submitSignal" -> handle_submit_signal(payload, ctx, assigns)
    "noop" -> handle_noop(payload, ctx, assigns)
    "requestOps" -> handle_request_ops(payload, ctx, assigns)
    _ -> NoReplyErased(assigns: ctx.assigns)
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// connect_document
// ─────────────────────────────────────────────────────────────────────────────

fn handle_connect_document(
  payload: Dynamic,
  ctx: SocketContext,
  assigns: DocumentAssigns,
) -> HandleResultErased {
  case assigns {
    Connected(..) -> {
      // Already connected, ignore
      NoReplyErased(assigns: ctx.assigns)
    }
    Pending(tenant_id: tenant_id, document_id: document_id) -> {
      // Decode fields - use optional_field so missing keys return None
      // instead of failing the entire decoder
      let field_decoder = {
        use msg_tenant_id <- decode.optional_field(
          "tenantId",
          None,
          decode.optional(decode.string),
        )
        use msg_doc_id <- decode.optional_field(
          "id",
          None,
          decode.optional(decode.string),
        )
        use token <- decode.optional_field(
          "token",
          None,
          decode.optional(decode.string),
        )
        use client <- decode.optional_field(
          "client",
          None,
          decode.optional(decode.dynamic),
        )
        use mode <- decode.optional_field(
          "mode",
          None,
          decode.optional(decode.string),
        )
        decode.success(#(msg_tenant_id, msg_doc_id, token, client, mode))
      }

      case decode.run(payload, field_decoder) {
        Error(_) -> {
          push_connect_error(ctx, 400, "Invalid connect_document payload")
          NoReplyErased(assigns: ctx.assigns)
        }
        Ok(#(msg_tenant_id, msg_doc_id, token, client, mode)) -> {
          // Check required fields
          case msg_tenant_id, msg_doc_id, token, client {
            Some(tid), Some(did), Some(tok), Some(_) -> {
              let connect_mode = option.unwrap(mode, "write")

              // Validate tenant/document match
              case tid == tenant_id && did == document_id {
                False -> {
                  push_connect_error(
                    ctx,
                    400,
                    "Tenant/document ID mismatch with topic",
                  )
                  NoReplyErased(assigns: ctx.assigns)
                }
                True -> {
                  do_connect(
                    tok,
                    tenant_id,
                    document_id,
                    connect_mode,
                    payload,
                    ctx,
                  )
                }
              }
            }
            _, _, _, _ -> {
              push_connect_error(
                ctx,
                400,
                "Missing required fields: tenantId, id, token, client",
              )
              NoReplyErased(assigns: ctx.assigns)
            }
          }
        }
      }
    }
  }
}

fn do_connect(
  token: String,
  tenant_id: String,
  document_id: String,
  mode: String,
  payload: Dynamic,
  ctx: SocketContext,
) -> HandleResultErased {
  // Validate JWT: verify, check expiration, check scopes
  case validate_token(token, tenant_id, mode) {
    Error(#(code, message)) -> {
      push_connect_error(ctx, code, message)
      NoReplyErased(assigns: ctx.assigns)
    }
    Ok(claims) -> {
      do_connect_with_session(
        tenant_id,
        document_id,
        mode,
        claims,
        payload,
        ctx,
      )
    }
  }
}

/// Validate a JWT token: verify signature, check expiration, and check scopes.
/// Returns Ok(claims) on success, or Error(#(code, message)) on failure.
fn validate_token(
  token: String,
  tenant_id: String,
  mode: String,
) -> Result(Dynamic, #(Int, String)) {
  let verify_result = jwt_verify(token, tenant_id)

  case decode_result(verify_result) {
    Error(_) -> Error(#(401, "Invalid authentication token"))
    Ok(claims) -> {
      case jwt_expired(claims) {
        True -> Error(#(401, "Token has expired"))
        False -> {
          case jwt_has_read_scope(claims) {
            False -> Error(#(403, "Token missing required scope: doc:read"))
            True -> {
              case mode == "write" && !jwt_has_write_scope(claims) {
                True -> Error(#(403, "Write mode requires doc:write scope"))
                False -> Ok(claims)
              }
            }
          }
        }
      }
    }
  }
}

fn do_connect_with_session(
  tenant_id: String,
  document_id: String,
  mode: String,
  claims: Dynamic,
  payload: Dynamic,
  ctx: SocketContext,
) -> HandleResultErased {
  // Get or create session
  let session_result = registry_get_or_create_session(tenant_id, document_id)

  case decode_result(session_result) {
    Error(_) -> {
      push_connect_error(ctx, 500, "Failed to start document session")
      NoReplyErased(assigns: ctx.assigns)
    }
    Ok(session_pid) -> {
      // Client join - pass handler_pid so Session sends {:op}/{:signal} to it
      let join_result =
        session_client_join(session_pid, payload, ctx.handler_pid)

      case decode_ok_tuple3(join_result) {
        Error(_) -> {
          push_connect_error(ctx, 500, "Failed to join document session")
          NoReplyErased(assigns: ctx.assigns)
        }
        Ok(#(client_id, response)) -> {
          // Notify handler about session PID so it can monitor it
          let _ = notify_handler_session(ctx.handler_pid, session_pid)

          // Push success response
          push_dynamic_to_ctx(ctx, "connect_document_success", response)

          // Update assigns to Connected
          let new_assigns =
            Connected(
              tenant_id: tenant_id,
              document_id: document_id,
              client_id: client_id,
              mode: mode,
              session_pid: session_pid,
              claims: claims,
            )

          NoReplyErased(assigns: to_dynamic(new_assigns))
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// submitOp
// ─────────────────────────────────────────────────────────────────────────────

fn handle_submit_op(
  payload: Dynamic,
  ctx: SocketContext,
  assigns: DocumentAssigns,
) -> HandleResultErased {
  case assigns {
    Pending(..) -> {
      push_nack(ctx, 400, "BadRequestError", "Client not connected")
      NoReplyErased(assigns: ctx.assigns)
    }
    Connected(
      client_id: expected_client_id,
      mode: mode,
      session_pid: session_pid,
      claims: claims,
      ..,
    ) -> {
      case
        validate_and_submit_op(
          payload,
          expected_client_id,
          mode,
          claims,
          session_pid,
          ctx,
        )
      {
        Ok(Nil) -> NoReplyErased(assigns: ctx.assigns)
        Error(Nil) -> NoReplyErased(assigns: ctx.assigns)
      }
    }
  }
}

/// Validate and submit an operation. Pushes nack on any validation failure.
/// Returns Ok(Nil) on success, Error(Nil) on failure (nack already sent).
fn validate_and_submit_op(
  payload: Dynamic,
  expected_client_id: String,
  mode: String,
  claims: Dynamic,
  session_pid: Dynamic,
  ctx: SocketContext,
) -> Result(Nil, Nil) {
  // Decode clientId and messageBatches
  let op_decoder = {
    use client_id <- decode.subfield(
      ["clientId"],
      decode.optional(decode.string),
    )
    use batches <- decode.subfield(
      ["messageBatches"],
      decode.optional(decode.dynamic),
    )
    decode.success(#(client_id, batches))
  }

  case decode.run(payload, op_decoder) {
    Ok(#(Some(client_id), Some(batches))) -> {
      // Validate client ID matches
      case client_id != expected_client_id {
        True -> {
          push_nack(
            ctx,
            400,
            "BadRequestError",
            "Client ID mismatch: expected "
              <> expected_client_id
              <> ", got "
              <> client_id,
          )
          Error(Nil)
        }
        False ->
          validate_write_and_submit(
            mode,
            claims,
            session_pid,
            client_id,
            batches,
            ctx,
          )
      }
    }
    _ -> {
      push_nack(
        ctx,
        400,
        "BadRequestError",
        "Malformed submitOp: missing clientId or messageBatches",
      )
      Error(Nil)
    }
  }
}

/// Check write permissions and submit ops to session.
fn validate_write_and_submit(
  mode: String,
  claims: Dynamic,
  session_pid: Dynamic,
  client_id: String,
  batches: Dynamic,
  ctx: SocketContext,
) -> Result(Nil, Nil) {
  case mode == "read" {
    True -> {
      push_nack(
        ctx,
        403,
        "InvalidScopeError",
        "Read-only clients cannot submit operations",
      )
      Error(Nil)
    }
    False -> {
      case jwt_has_write_scope(claims) {
        False -> {
          push_nack(ctx, 403, "InvalidScopeError", "Missing doc:write scope")
          Error(Nil)
        }
        True -> {
          let submit_result =
            session_submit_ops(session_pid, client_id, batches)
          case is_error_result(submit_result) {
            True -> {
              let nacks = extract_error_value(submit_result)
              push_dynamic_to_ctx(ctx, "nack", make_nack_map("", nacks))
              Error(Nil)
            }
            False -> Ok(Nil)
          }
        }
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// submitSignal
// ─────────────────────────────────────────────────────────────────────────────

fn handle_submit_signal(
  payload: Dynamic,
  ctx: SocketContext,
  assigns: DocumentAssigns,
) -> HandleResultErased {
  case assigns {
    Pending(..) -> NoReplyErased(assigns: ctx.assigns)
    Connected(client_id: expected_client_id, session_pid: session_pid, ..) -> {
      let signal_decoder = {
        use client_id <- decode.subfield(
          ["clientId"],
          decode.optional(decode.string),
        )
        use batches <- decode.subfield(
          ["contentBatches"],
          decode.optional(decode.dynamic),
        )
        decode.success(#(client_id, batches))
      }

      case decode.run(payload, signal_decoder) {
        Ok(#(Some(client_id), Some(batches))) -> {
          case client_id == expected_client_id {
            False -> NoReplyErased(assigns: ctx.assigns)
            True -> {
              let _ = session_submit_signals(session_pid, client_id, batches)
              NoReplyErased(assigns: ctx.assigns)
            }
          }
        }
        _ -> NoReplyErased(assigns: ctx.assigns)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// noop
// ─────────────────────────────────────────────────────────────────────────────

fn handle_noop(
  payload: Dynamic,
  ctx: SocketContext,
  assigns: DocumentAssigns,
) -> HandleResultErased {
  case assigns {
    Pending(..) -> NoReplyErased(assigns: ctx.assigns)
    Connected(client_id: expected_client_id, session_pid: session_pid, ..) -> {
      let noop_decoder = {
        use client_id <- decode.subfield(["clientId"], decode.string)
        use rsn <- decode.subfield(["referenceSequenceNumber"], decode.int)
        decode.success(#(client_id, rsn))
      }

      case decode.run(payload, noop_decoder) {
        Ok(#(client_id, rsn)) -> {
          case client_id == expected_client_id {
            True -> {
              let _ = session_update_client_rsn(session_pid, client_id, rsn)
              NoReplyErased(assigns: ctx.assigns)
            }
            False -> NoReplyErased(assigns: ctx.assigns)
          }
        }
        Error(_) -> NoReplyErased(assigns: ctx.assigns)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// requestOps
// ─────────────────────────────────────────────────────────────────────────────

fn handle_request_ops(
  payload: Dynamic,
  ctx: SocketContext,
  assigns: DocumentAssigns,
) -> HandleResultErased {
  case assigns {
    Pending(..) -> NoReplyErased(assigns: ctx.assigns)
    Connected(document_id: document_id, session_pid: session_pid, ..) -> {
      let from_decoder = {
        use sn <- decode.subfield(["from"], decode.int)
        decode.success(sn)
      }

      case decode.run(payload, from_decoder) {
        Ok(from_sn) -> {
          let ops_result = session_get_ops_since(session_pid, from_sn)

          case decode_result(ops_result) {
            Ok(ops) -> {
              // Check if list is non-empty
              case is_empty_list(ops) {
                True -> NoReplyErased(assigns: ctx.assigns)
                False -> {
                  push_dynamic_to_ctx(ctx, "op", make_op_map(document_id, ops))
                  NoReplyErased(assigns: ctx.assigns)
                }
              }
            }
            Error(_) -> NoReplyErased(assigns: ctx.assigns)
          }
        }
        Error(_) -> NoReplyErased(assigns: ctx.assigns)
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Terminate
// ─────────────────────────────────────────────────────────────────────────────

fn terminate(_reason: channel.StopReason, ctx: SocketContext) -> Nil {
  let assigns = unsafe_coerce_assigns(ctx.assigns)
  case assigns {
    Connected(session_pid: session_pid, client_id: client_id, ..) -> {
      let _ = session_client_leave(session_pid, client_id)
      Nil
    }
    Pending(..) -> Nil
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

/// Parse "document:{tenant_id}:{document_id}" topic
fn parse_topic(topic_name: String) -> Result(#(String, String), Nil) {
  case string.split(topic_name, ":") {
    ["document", tenant_id, document_id] -> Ok(#(tenant_id, document_id))
    _ -> Error(Nil)
  }
}

/// Push a connect_document_error to the client
fn push_connect_error(ctx: SocketContext, code: Int, message: String) -> Nil {
  let payload =
    json.object([
      #("code", json.int(code)),
      #("message", json.string(message)),
    ])
  push_json_to_ctx(ctx, "connect_document_error", payload)
}

/// Push a nack to the client
fn push_nack(
  ctx: SocketContext,
  code: Int,
  error_type: String,
  message: String,
) -> Nil {
  let nack_content =
    json.object([
      #("code", json.int(code)),
      #("type", json.string(error_type)),
      #("message", json.string(message)),
    ])
  let nack =
    json.object([
      #("operation", json.null()),
      #("sequenceNumber", json.int(-1)),
      #("content", nack_content),
    ])
  let payload =
    json.object([
      #("clientId", json.string("")),
      #("nacks", json.preprocessed_array([nack])),
    ])
  push_json_to_ctx(ctx, "nack", payload)
}

/// Push a Json message to the socket via wire protocol
fn push_json_to_ctx(
  ctx: SocketContext,
  event: String,
  payload: json.Json,
) -> Nil {
  let msg =
    json.to_string(
      json.preprocessed_array([
        json.null(),
        json.null(),
        json.string(ctx.topic),
        json.string(event),
        payload,
      ]),
    )
  let _ = ctx.send(msg)
  Nil
}

/// Push a Dynamic value as a message to the socket via wire protocol
fn push_dynamic_to_ctx(
  ctx: SocketContext,
  event: String,
  payload: Dynamic,
) -> Nil {
  let msg = dynamic_push(ctx.topic, event, payload)
  let _ = ctx.send(msg)
  Nil
}

/// Decode a {:ok, value} / {:error, reason} Elixir result tuple.
/// Erlang tuples are accessed by integer index in gleam decoders.
fn decode_result(value: Dynamic) -> Result(Dynamic, Dynamic) {
  // Try to decode as a 2-tuple where element 0 is the atom 'ok'
  let ok_decoder = {
    use tag <- decode.subfield([0], decode.dynamic)
    use val <- decode.subfield([1], decode.dynamic)
    decode.success(#(tag, val))
  }

  case decode.run(value, ok_decoder) {
    Ok(#(tag, val)) -> {
      case dynamic.classify(tag) {
        "Atom" -> {
          case atom_to_string(tag) {
            "ok" -> Ok(val)
            _ -> Error(value)
          }
        }
        _ -> Error(value)
      }
    }
    Error(_) -> Error(value)
  }
}

/// Decode {:ok, client_id, response} 3-element tuple
/// Session.client_join returns {:reply, {:ok, client_id, response}, state}
/// so the GenServer.call result is {:ok, client_id, response}
fn decode_ok_tuple3(value: Dynamic) -> Result(#(String, Dynamic), Nil) {
  let decoder = {
    use tag <- decode.subfield([0], decode.dynamic)
    use client_id <- decode.subfield([1], decode.string)
    use response <- decode.subfield([2], decode.dynamic)
    decode.success(#(tag, client_id, response))
  }

  case decode.run(value, decoder) {
    Ok(#(tag, client_id, response)) -> {
      case dynamic.classify(tag) {
        "Atom" -> {
          case atom_to_string(tag) {
            "ok" -> Ok(#(client_id, response))
            _ -> Error(Nil)
          }
        }
        _ -> Error(Nil)
      }
    }
    Error(_) -> Error(Nil)
  }
}

/// Check if an Elixir result is {:error, _}
fn is_error_result(value: Dynamic) -> Bool {
  let tag_decoder = {
    use tag <- decode.subfield([0], decode.dynamic)
    decode.success(tag)
  }
  case decode.run(value, tag_decoder) {
    Ok(tag) -> {
      case dynamic.classify(tag) {
        "Atom" -> atom_to_string(tag) == "error"
        _ -> False
      }
    }
    Error(_) -> False
  }
}

/// Extract the error value from {:error, value}
fn extract_error_value(value: Dynamic) -> Dynamic {
  let decoder = {
    use val <- decode.subfield([1], decode.dynamic)
    decode.success(val)
  }
  case decode.run(value, decoder) {
    Ok(v) -> v
    Error(_) -> value
  }
}

/// Check if a Dynamic value is an empty list
fn is_empty_list(value: Dynamic) -> Bool {
  case decode.run(value, decode.list(decode.dynamic)) {
    Ok([]) -> True
    _ -> False
  }
}
