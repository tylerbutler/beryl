import gleam/dynamic/decode
import gleam/json
import gleam/option.{Some}
import gleeunit
import gleeunit/should
import lustre_presence_client
import lustre_presence_client/channel
import lustre_presence_client/presence

pub fn main() -> Nil {
  gleeunit.main()
}

fn payload(raw: String) {
  let assert Ok(value) = json.parse(from: raw, using: decode.dynamic)
  value
}

pub fn presence_state_and_diff_update_online_users_test() {
  let assert Ok(presence.State(initial)) =
    presence.decode_state(payload(
      "{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}}",
    ))
  let assert Ok(presence.Diff(joins, leaves)) =
    presence.decode_diff(payload(
      "{\"joins\":{\"user:2\":{\"metas\":[{\"name\":\"Bob\",\"avatar_url\":\"/bob.png\",\"phx_ref\":\"2\"}]}},\"leaves\":{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}}}",
    ))

  let assert Ok(updated) =
    presence.update(initial, presence.Diff(joins, leaves))

  presence.present_users(updated)
  |> should.equal([
    presence.PresentUser(id: "user:2", name: "Bob", avatar_url: "/bob.png"),
  ])
}

pub fn duplicate_join_refs_do_not_duplicate_users_test() {
  let assert Ok(event) =
    presence.decode_state(payload(
      "{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}}",
    ))
  let assert Ok(initial) = presence.update(presence.new(), event)
  let assert Ok(presence.Diff(joins, leaves)) =
    presence.decode_diff(payload(
      "{\"joins\":{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}},\"leaves\":{}}",
    ))
  let assert Ok(updated) =
    presence.update(initial, presence.Diff(joins, leaves))

  presence.present_users(updated)
  |> should.equal([
    presence.PresentUser(id: "user:1", name: "Ada", avatar_url: "/ada.png"),
  ])
}

pub fn channel_events_map_through_one_lustre_message_branch_test() {
  let model = lustre_presence_client.initial_model()
  let #(connected, _) =
    lustre_presence_client.update(
      model,
      lustre_presence_client.ChannelEvent(channel.Connected),
    )
  connected.connection |> should.equal(lustre_presence_client.Connected)

  let #(reconnecting, _) =
    lustre_presence_client.update(
      connected,
      lustre_presence_client.ChannelEvent(channel.Reconnecting),
    )
  reconnecting.connection
  |> should.equal(lustre_presence_client.Reconnecting)
}

pub fn invalid_presence_state_preserves_decode_errors_test() -> Nil {
  let assert Error(presence.InvalidState(errors)) =
    presence.decode_state(payload(
      "{\"user:1\":{\"metas\":[{\"name\":42,\"avatar_url\":false,\"phx_ref\":\"1\"}]}}",
    ))

  errors
  |> should.equal([
    decode.DecodeError(expected: "String", found: "Int", path: [
      "user:1",
      "metas",
      "0",
      "name",
    ]),
    decode.DecodeError(expected: "String", found: "Bool", path: [
      "user:1",
      "metas",
      "0",
      "avatar_url",
    ]),
  ])
}

pub fn invalid_presence_state_reaches_the_error_boundary_test() -> Nil {
  let assert Ok(presence.State(initial)) =
    presence.decode_state(payload(
      "{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}}",
    ))
  let assert Error(error) =
    presence.decode_state(payload("{\"user:1\":{\"metas\":\"invalid\"}}"))

  error
  |> should.equal(
    presence.InvalidState([
      decode.DecodeError(expected: "List", found: "String", path: [
        "user:1",
        "metas",
      ]),
    ]),
  )

  let #(model, _) =
    lustre_presence_client.update(
      lustre_presence_client.Model(
        ..lustre_presence_client.initial_model(),
        presence: initial,
        connection: lustre_presence_client.Connected,
      ),
      lustre_presence_client.ChannelEvent(channel.DecodeFailed(error)),
    )

  model.error
  |> should.equal(Some(
    "The server sent invalid presence state. At user:1.metas: expected List, found String.",
  ))
  model.connection |> should.equal(lustre_presence_client.Connected)
  model.presence |> should.equal(initial)
}

pub fn invalid_presence_diff_preserves_join_errors_test() -> Nil {
  presence.decode_diff(payload(
    "{\"joins\":{\"user:1\":{\"metas\":[{\"name\":42,\"avatar_url\":\"/ada.png\",\"phx_ref\":\"1\"}]}},\"leaves\":{}}",
  ))
  |> should.equal(
    Error(
      presence.InvalidDiff([
        decode.DecodeError(expected: "String", found: "Int", path: [
          "joins",
          "user:1",
          "metas",
          "0",
          "name",
        ]),
      ]),
    ),
  )
}

pub fn invalid_presence_diff_preserves_leave_errors_test() -> Nil {
  presence.decode_diff(payload(
    "{\"joins\":{},\"leaves\":{\"user:1\":{\"metas\":[{\"name\":\"Ada\",\"avatar_url\":\"/ada.png\",\"phx_ref\":42}]}}}",
  ))
  |> should.equal(
    Error(
      presence.InvalidDiff([
        decode.DecodeError(expected: "String", found: "Int", path: [
          "leaves",
          "user:1",
          "metas",
          "0",
          "phx_ref",
        ]),
      ]),
    ),
  )
}

pub fn missing_presence_diff_field_reaches_the_error_boundary_test() -> Nil {
  let assert Error(error) = presence.decode_diff(payload("{\"joins\":{}}"))

  error
  |> should.equal(
    presence.InvalidDiff([
      decode.DecodeError(expected: "Field", found: "Nothing", path: ["leaves"]),
    ]),
  )

  let #(model, _) =
    lustre_presence_client.update(
      lustre_presence_client.initial_model(),
      lustre_presence_client.ChannelEvent(channel.DecodeFailed(error)),
    )

  model.error
  |> should.equal(Some(
    "The server sent an invalid presence diff. At leaves: expected Field, found Nothing.",
  ))
}

pub fn presence_error_message_includes_all_decode_errors_test() -> Nil {
  let assert Error(error) =
    presence.decode_state(payload(
      "{\"user:1\":{\"metas\":[{\"name\":42,\"avatar_url\":false,\"phx_ref\":\"1\"}]}}",
    ))

  presence.error_to_string(error)
  |> should.equal(
    "The server sent invalid presence state. At user:1.metas.0.name: expected String, found Int. At user:1.metas.0.avatar_url: expected String, found Bool.",
  )
}

pub fn invalid_presence_root_has_a_payload_location_test() -> Nil {
  let assert Error(error) = presence.decode_state(payload("[]"))

  error
  |> should.equal(
    presence.InvalidState([
      decode.DecodeError(expected: "Dict", found: "Array", path: []),
    ]),
  )
  presence.error_to_string(error)
  |> should.equal(
    "The server sent invalid presence state. At payload: expected Dict, found Array.",
  )
}
