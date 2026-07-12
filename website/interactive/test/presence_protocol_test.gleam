import beryl_site/presence/protocol
import gleam/dict
import gleeunit/should

pub fn decodes_join_reply_test() {
  let encoded =
    "{\"compatibility_version\":1,\"client_id\":\"client-a\",\"presence_state\":{\"client-a\":{\"metas\":[{\"name\":\"Alice\",\"color\":\"emerald\",\"phx_ref\":\"ref-a\"}]}}}"
  let assert Ok(reply) = protocol.decode_join(encoded)
  reply.compatibility_version |> should.equal(1)
  reply.client_id |> should.equal("client-a")
  dict.size(reply.presence_state) |> should.equal(1)
}

pub fn rejects_join_reply_without_compatibility_version_test() {
  protocol.decode_join("{\"client_id\":\"client-a\",\"presence_state\":{}}")
  |> should.equal(Error("invalid_join_reply"))
}

pub fn applies_join_and_leave_diff_by_phx_ref_test() {
  let state =
    protocol.state([
      #("client-a", [protocol.Meta("Alice", "emerald", "ref-a")]),
    ])
  let diff =
    protocol.PresenceDiff(
      joins: protocol.state([
        #("client-b", [protocol.Meta("Bob", "magenta", "ref-b")]),
      ]),
      leaves: protocol.state([
        #("client-a", [protocol.Meta("Alice", "emerald", "ref-a")]),
      ]),
    )

  let updated = protocol.apply_diff(state, diff)
  dict.has_key(updated, "client-a") |> should.be_false
  dict.has_key(updated, "client-b") |> should.be_true
}
