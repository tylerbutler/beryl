import beryl
import beryl/event
import gleam/otp/static_supervisor
import gleam/result

pub fn start(
  config: beryl.Config,
  init init: fn(event.ConnectInfo(msg)) -> #(model, List(event.Effect)),
  update update: fn(model, event.Event(msg)) -> event.Next(model, msg),
) -> Result(beryl.Sockets, beryl.ConfigError) {
  use #(sockets, spec) <- result.try(beryl.child_spec(config, init:, update:))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  Ok(sockets)
}
