import beryl
import beryl/channel
import beryl/wire
import blog_series/channels
import blog_series/server
import blog_series/store
import blog_series/timer

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
