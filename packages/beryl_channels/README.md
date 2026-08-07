# beryl_channels

Composable channel layer for [beryl](https://hex.pm/packages/beryl)
real-time sockets.

> [!IMPORTANT]
> beryl is not yet 1.0. The API is unstable, features may be removed in minor
> releases, and quality should not be considered production-ready.

A channel is a topic pattern plus a typed `join` callback, and a joined
channel is a record of closures over that channel's own private state.
Register a list of handlers and the layer routes each socket event to the
channel that owns its topic — no hand-written message union and no
hand-written router.

```gleam
import beryl_channels
import beryl_channels/channel
import gleam/json

pub fn room() -> channel.Handler {
  channel.handler("room:*", fn(_info, _topic, _payload) {
    let callbacks =
      channel.callbacks()
      |> channel.on_message(fn(count, message) {
        channel.continue_with(
          count + 1,
          channel.actions()
            |> channel.broadcast(message.event, json.int(count + 1)),
        )
      })

    channel.accept(channel.joined(0, callbacks))
  })
}

pub fn main() {
  let assert Ok(Nil) = beryl_channels.validate_handlers([room()])
}
```

Each channel picks its own private state type and its own server-side
message type, and neither escapes: handlers seal both in closures, so a
single `List(channel.Handler)` holds channels that agree on nothing. No
value is erased to `Dynamic` and no unchecked coercion is involved.

The supervised socket entry point that builds a child specification from
a handler table lands together with the dispatch adapter; until then this
package provides the handler surface, the error surface, and handler-table
validation.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl_channels>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_channels`)

## Licence

MIT
