import beryl
import beryl/wire
import live_poll/raw
import live_poll/server
import live_poll/store
import live_poll/timer

pub fn main() {
  let assert Ok(polls) = store.start()
  let assert Ok(clock) = timer.start()
  let assert Ok(#(sockets, spec)) =
    beryl.child_spec(
      beryl.config(wire.phoenix_codec()),
      init: raw.init,
      update: raw.update(raw.ReadOnly, polls, clock, 60_000),
    )
  server.run(sockets, spec, "Step 01 - raw joins and state", 8101, False, False)
}
