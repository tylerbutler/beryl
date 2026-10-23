import beryl/channel
import gleam/json
import lustre_presence/auth

pub fn channel() -> channel.Handler {
  channel.handler("page:dashboard", fn(context) {
    case auth.from_metadata(context.seed.metadata) {
      Error(Nil) ->
        channel.reject(
          json.object([
            #("reason", json.string("unauthorized")),
          ]),
        )
      Ok(user) ->
        channel.accept(Nil)
        |> channel.with_reply(
          json.object([
            #("user_id", json.string(user.id)),
            #("name", json.string(user.name)),
          ]),
        )
    }
  })
}
