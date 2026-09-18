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

pub fn invalid_presence_payload_is_an_explicit_error_test() {
  presence.decode_state(payload("{\"user:1\":{\"metas\":\"invalid\"}}"))
  |> should.equal(Error(presence.InvalidState))

  let #(model, _) =
    lustre_presence_client.update(
      lustre_presence_client.initial_model(),
      lustre_presence_client.ChannelEvent(channel.DecodeFailed(
        presence.InvalidState,
      )),
    )

  model.error
  |> should.equal(Some("The server sent invalid presence data."))
}
