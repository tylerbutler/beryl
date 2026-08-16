import beryl/presence
import beryl/presence/wire as presence_wire
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit/should

fn sample_diff() -> presence.Diff {
  presence.diff(
    joins: [
      #("room:lobby", [
        presence.PresenceEntry(
          session_id: "socket-1",
          key: "user:1",
          meta: json.object([#("status", json.string("online"))]),
        ),
        presence.PresenceEntry(
          session_id: "socket-2",
          key: "user:1",
          meta: json.object([#("status", json.string("away"))]),
        ),
        presence.PresenceEntry(
          session_id: "socket-3",
          key: "user:2",
          meta: json.object([#("device", json.string("mobile"))]),
        ),
      ]),
    ],
    leaves: [
      #("room:lobby", [
        presence.PresenceEntry(
          session_id: "socket-4",
          key: "user:3",
          meta: json.object([#("status", json.string("offline"))]),
        ),
      ]),
      #("room:other", [
        presence.PresenceEntry(
          session_id: "socket-5",
          key: "ignored",
          meta: json.object([#("status", json.string("away"))]),
        ),
      ]),
    ],
  )
}

pub fn encode_diff_groups_metas_by_presence_key_for_topic_test() {
  let payload = presence_wire.encode_diff(sample_diff(), "room:lobby")
  let encoded = json.to_string(payload)

  let user1_metas_decoder = {
    use user1_metas <- decode.field("joins", {
      use user1_metas <- decode.field("user:1", {
        use user1_metas <- decode.field(
          "metas",
          decode.list({
            use status <- decode.field("status", decode.string)
            decode.success(status)
          }),
        )
        decode.success(user1_metas)
      })
      decode.success(user1_metas)
    })
    decode.success(user1_metas)
  }
  let assert Ok(user1_metas) = json.parse(encoded, user1_metas_decoder)
  user1_metas |> list.length |> should.equal(2)

  let user2_metas_decoder = {
    use user2_metas <- decode.field("joins", {
      use user2_metas <- decode.field("user:2", {
        use user2_metas <- decode.field(
          "metas",
          decode.list({
            use device <- decode.field("device", decode.string)
            decode.success(device)
          }),
        )
        decode.success(user2_metas)
      })
      decode.success(user2_metas)
    })
    decode.success(user2_metas)
  }
  let assert Ok(user2_metas) = json.parse(encoded, user2_metas_decoder)
  user2_metas |> should.equal(["mobile"])

  let user3_metas_decoder = {
    use user3_metas <- decode.field("leaves", {
      use user3_metas <- decode.field("user:3", {
        use user3_metas <- decode.field(
          "metas",
          decode.list({
            use status <- decode.field("status", decode.string)
            decode.success(status)
          }),
        )
        decode.success(user3_metas)
      })
      decode.success(user3_metas)
    })
    decode.success(user3_metas)
  }
  let assert Ok(user3_metas) = json.parse(encoded, user3_metas_decoder)
  user3_metas |> should.equal(["offline"])
}

pub fn encode_diff_omits_other_topics_test() {
  let payload = presence_wire.encode_diff(sample_diff(), "room:lobby")

  json.to_string(payload)
  |> string.contains("ignored")
  |> should.be_false
}

pub fn encode_state_groups_metas_by_presence_key_test() {
  let entries = [
    presence.PresenceEntry(
      session_id: "socket-1",
      key: "user:1",
      meta: json.object([#("status", json.string("online"))]),
    ),
    presence.PresenceEntry(
      session_id: "socket-2",
      key: "user:1",
      meta: json.object([#("status", json.string("away"))]),
    ),
    presence.PresenceEntry(
      session_id: "socket-3",
      key: "user:2",
      meta: json.object([#("device", json.string("mobile"))]),
    ),
  ]

  let encoded = json.to_string(presence_wire.encode_state(entries))

  let user1_decoder = {
    use metas <- decode.field("user:1", {
      use metas <- decode.field(
        "metas",
        decode.list({
          use status <- decode.field("status", decode.string)
          decode.success(status)
        }),
      )
      decode.success(metas)
    })
    decode.success(metas)
  }
  let assert Ok(user1_metas) = json.parse(encoded, user1_decoder)
  user1_metas |> list.length |> should.equal(2)

  let user2_decoder = {
    use metas <- decode.field("user:2", {
      use metas <- decode.field(
        "metas",
        decode.list({
          use device <- decode.field("device", decode.string)
          decode.success(device)
        }),
      )
      decode.success(metas)
    })
    decode.success(metas)
  }
  let assert Ok(user2_metas) = json.parse(encoded, user2_decoder)
  user2_metas |> should.equal(["mobile"])
}

pub fn tracked_metas_carry_phx_ref_test() {
  let assert Ok(p) = presence.start(presence.default_config("wire-node"))

  let ref =
    presence.track(
      p,
      "room:lobby",
      "user:1",
      "socket-1",
      json.object([#("status", json.string("online"))]),
    )

  let assert [entry] = presence_entries(p, "room:lobby")

  let phx_ref_decoder = {
    use phx_ref <- decode.field("phx_ref", decode.string)
    decode.success(phx_ref)
  }
  let assert Ok(phx_ref) =
    json.parse(json.to_string(entry.meta), phx_ref_decoder)
  phx_ref |> should.equal(ref)

  // The user's own meta fields are preserved alongside phx_ref
  let status_decoder = {
    use status <- decode.field("status", decode.string)
    decode.success(status)
  }
  let assert Ok(status) = json.parse(json.to_string(entry.meta), status_decoder)
  status |> should.equal("online")
}

pub fn tracked_multi_session_metas_have_distinct_phx_refs_test() {
  let assert Ok(p) = presence.start(presence.default_config("wire-node-2"))

  let ref1 =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.object([]))
  let ref2 =
    presence.track(p, "room:lobby", "user:1", "socket-2", json.object([]))

  { ref1 != ref2 } |> should.be_true

  let entries = presence_entries(p, "room:lobby")
  entries |> list.length |> should.equal(2)

  let phx_ref_decoder = {
    use phx_ref <- decode.field("phx_ref", decode.string)
    decode.success(phx_ref)
  }
  let refs =
    list.filter_map(entries, fn(entry) {
      json.parse(json.to_string(entry.meta), phx_ref_decoder)
    })
  refs |> list.length |> should.equal(2)
  list.contains(refs, ref1) |> should.be_true
  list.contains(refs, ref2) |> should.be_true
}

pub fn non_object_meta_is_stored_unchanged_test() {
  let assert Ok(p) = presence.start(presence.default_config("wire-node-3"))

  let _ref =
    presence.track(p, "room:lobby", "user:1", "socket-1", json.string("plain"))

  let assert [entry] = presence_entries(p, "room:lobby")
  json.to_string(entry.meta) |> should.equal("\"plain\"")
}

fn presence_entries(
  tracker: presence.Presence,
  topic: String,
) -> List(presence.PresenceEntry) {
  let assert Ok(entries) = presence.list(tracker, topic)
  entries
}
