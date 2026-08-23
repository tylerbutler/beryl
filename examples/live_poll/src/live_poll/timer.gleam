import gleam/erlang/process.{type Subject}
import gleam/otp/actor
import gleam/result

pub opaque type Timer {
  Timer(subject: Subject(Message))
}

type Message {
  Run(fn() -> Nil)
}

pub fn start() -> Result(Timer, actor.StartError) {
  actor.new(Nil)
  |> actor.on_message(fn(state, message) {
    let Run(action) = message
    action()
    actor.continue(state)
  })
  |> actor.start
  |> result.map(fn(started) { Timer(started.data) })
}

pub fn after(timer: Timer, milliseconds: Int, action: fn() -> Nil) -> Nil {
  let _ = process.send_after(timer.subject, milliseconds, Run(action))
  Nil
}
