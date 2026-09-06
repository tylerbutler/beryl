import beryl
import beryl/channel
import beryl/wire
import live_poll/channel_handler
import live_poll/server
import live_poll/store
import live_poll/timer

pub fn main() -> Nil {
  let assert Ok(polls) = store.start()
  let assert Ok(clock) = timer.start()
  let assert Ok(#(sockets, child_specification)) =
    channel.child_spec(
      beryl.config(wire.phoenix_codec()),
      handlers: channel_handler.handlers(polls, clock, 60_000),
    )
  server.run(
    sockets,
    child_specification,
    "Step 04 - composed channels",
    8104,
    server.HealthEndpointDisabled,
    server.GuideChannelEnabled,
  )
}
