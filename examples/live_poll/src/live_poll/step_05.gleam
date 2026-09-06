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
  let config =
    beryl.config(wire.phoenix_codec())
    |> beryl.with_heartbeat(timeout_ms: 45_000)
    |> beryl.with_max_connections(500)
    |> beryl.with_max_connections_per_ip(20)
    |> beryl.with_max_inbound_frame_bytes(16_384)
    |> beryl.with_frame_rate(per_second: 20, burst: 40)
    |> beryl.with_message_rate(per_second: 10, burst: 20)
    |> beryl.with_join_rate(per_second: 4, burst: 8)
    |> beryl.with_topic_rate(pattern: "poll:*", per_second: 5, burst: 10)

  let assert Ok(#(sockets, child_specification)) =
    channel.child_spec(
      config,
      handlers: channel_handler.handlers(polls, clock, 60_000),
    )
  server.run(
    sockets,
    child_specification,
    "Step 05 - production-shaped app",
    8105,
    server.HealthEndpointEnabled,
    server.GuideChannelEnabled,
  )
}
