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
import beryl
import beryl/wire
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
  let assert Ok(sockets) =
    beryl_channels.start(
      beryl.config(wire.phoenix_codec()),
      handlers: [room()],
    )
}
```

Each channel picks its own private state type and its own server-side
message type, and neither escapes: handlers seal both in closures, so a
single `List(channel.Handler)` holds channels that agree on nothing. No
value is erased to `Dynamic` and no unchecked coercion is involved.

`start` returns an ordinary `beryl.Sockets` handle, so it works with the
`beryl_mist` and `beryl_ewe` transports, `beryl.broadcast`, and
`beryl.stop`. Use `beryl_channels.child_spec` to embed a channel system in
an application's own supervision tree instead.

Handlers are consulted in registration order and the first matching
pattern owns the topic, so more specific patterns belong earlier in the
list. A join for a topic no handler matches is refused explicitly with
`{"reason": "unmatched topic"}` rather than left unanswered.

## Documentation

- Guides and API reference: <https://beryl.tylerbutler.com>
- Package docs: <https://hexdocs.pm/beryl_channels>
- Repository: <https://github.com/tylerbutler/beryl> (monorepo; this package
  lives in `packages/beryl_channels`)

## Licence

MIT
