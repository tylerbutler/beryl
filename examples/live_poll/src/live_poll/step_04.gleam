import beryl
import beryl/channel
import beryl/wire
import live_poll/channels
import live_poll/server
import live_poll/store
import live_poll/timer

pub fn main() {
  let assert Ok(polls) = store.start()
  let assert Ok(clock) = timer.start()
  let assert Ok(#(sockets, spec)) =
    channel.child_spec(
      beryl.config(wire.phoenix_codec()),
      handlers: channels.handlers(polls, clock, 60_000),
    )
  server.run(sockets, spec, "Step 04 - composed channels", 8104, False, True)
}
