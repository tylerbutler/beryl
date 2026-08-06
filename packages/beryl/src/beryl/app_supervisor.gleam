//// Lifecycle wrapper for the nested app-dispatch supervisor.
////
//// Erlang supervisors exit with `shutdown` both after intentional automatic
//// shutdown and after restart-intensity exhaustion. The outer transient child
//// cannot distinguish those cases by exit reason alone, so this wrapper tracks
//// intentional stops and translates only exhaustion into an abnormal exit.

import gleam/erlang/process
import gleam/otp/actor
import gleam/otp/static_supervisor

pub type Message {
  StopRuntime(started: process.Subject(Bool), finished: process.Subject(Nil))
  LinkedExit(process.ExitMessage)
}

type State {
  State(
    parent: process.Pid,
    supervisor: process.Pid,
    stopping: Bool,
    stop_runtime: fn(process.Subject(Nil)) -> Bool,
  )
}

/// Start a process that owns the nested supervisor and preserves the
/// distinction between intentional shutdown and restart-intensity exhaustion.
pub fn start(
  name: process.Name(Message),
  stop_runtime: fn(process.Subject(Nil)) -> Bool,
  start_supervisor: fn() ->
    Result(actor.Started(static_supervisor.Supervisor), actor.StartError),
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  let parent = process.self()

  actor.new_with_initialiser(5000, fn(subject) {
    process.trap_exits(True)
    case start_supervisor() {
      Error(error) -> Error(start_error_message(error))
      Ok(started) -> {
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_trapped_exits(LinkedExit)

        actor.initialised(State(
          parent: parent,
          supervisor: started.pid,
          stopping: False,
          stop_runtime: stop_runtime,
        ))
        |> actor.selecting(selector)
        |> actor.returning(started.data)
        |> Ok
      }
    }
  })
  |> actor.on_message(handle_message)
  |> actor.named(name)
  |> actor.start
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    StopRuntime(started, _) if state.stopping -> {
      process.send(started, False)
      actor.continue(state)
    }
    StopRuntime(started, finished) ->
      case state.stop_runtime(finished) {
        False -> {
          process.send(started, False)
          actor.continue(state)
        }
        True -> {
          process.send(started, True)
          actor.continue(State(..state, stopping: True))
        }
      }
    LinkedExit(process.ExitMessage(pid, _)) if pid == state.supervisor ->
      case state.stopping {
        True -> actor.stop()
        False -> {
          process.trap_exits(False)
          actor.stop_abnormal("app subtree restart intensity exceeded")
        }
      }
    LinkedExit(process.ExitMessage(pid, _)) if pid == state.parent -> {
      stop_supervisor(state.supervisor)
      actor.stop()
    }
    LinkedExit(_) -> actor.continue(state)
  }
}

fn start_error_message(error: actor.StartError) -> String {
  case error {
    actor.InitTimeout -> "app subtree supervisor start timed out"
    actor.InitFailed(reason) -> reason
    actor.InitExited(_) -> "app subtree supervisor exited during startup"
  }
}

@external(erlang, "beryl_ffi", "stop_supervisor")
fn stop_supervisor(pid: process.Pid) -> Nil
