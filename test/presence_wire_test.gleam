import beryl/presence
import beryl/presence/wire as presence_wire
import gleam/dynamic/decode
import gleam/json
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should

pub fn main() {
  gleeunit.main()
}

fn sample_diff() -> presence.Diff {
  presence.diff(
    joins: [
      #("room:lobby", [
        presence.PresenceEntry(
          pid: "socket-1",
          key: "user:1",
          meta: json.object([#("status", json.string("online"))]),
        ),
        presence.PresenceEntry(
          pid: "socket-2",
          key: "user:1",
          meta: json.object([#("status", json.string("away"))]),
        ),
        presence.PresenceEntry(
          pid: "socket-3",
          key: "user:2",
          meta: json.object([#("device", json.string("mobile"))]),
        ),
      ]),
    ],
    leaves: [
      #("room:lobby", [
        presence.PresenceEntry(
          pid: "socket-4",
          key: "user:3",
          meta: json.object([#("status", json.string("offline"))]),
        ),
      ]),
      #("room:other", [
        presence.PresenceEntry(
          pid: "socket-5",
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
