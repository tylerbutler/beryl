import beryl
import beryl/socket
import gleam/otp/static_supervisor
import gleam/result

pub fn start(
  config: beryl.Config,
  init init: fn(socket.ConnectInfo(msg)) -> #(model, List(socket.Effect)),
  update update: fn(model, socket.Input(msg)) -> socket.Next(model),
) -> Result(beryl.Sockets, beryl.ConfigError) {
  use #(sockets, spec) <- result.try(beryl.child_spec(config, init:, update:))
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(spec)
    |> static_supervisor.start()
  Ok(sockets)
}
