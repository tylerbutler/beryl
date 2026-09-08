//// Lifecycle wrapper for the nested app-dispatch supervisor.
////
//// Erlang supervisors exit with `shutdown` both after intentional automatic
//// shutdown and after restart-intensity exhaustion. The outer transient child
//// cannot distinguish those cases by exit reason alone, so this wrapper tracks
//// intentional stops and translates only exhaustion into an abnormal exit.

import beryl/overload
import beryl/work_queue
import gleam/erlang/process
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result

pub type StopAcceptance {
  StopAccepted
  StopRejected
}

pub type StopCompletion {
  StopCompleted
  StopIncomplete
}

pub type Message {
  WorkAvailable
  RecoverWork
  RuntimeStopped(completion: StopCompletion)
  RuntimeDown(process.Down)
  LinkedExit(process.ExitMessage)
  StopRuntime(
    started: fn(StopAcceptance) -> Nil,
    finished: process.Subject(StopCompletion),
  )
}

type StopState {
  Running
  Stopping(
    monitor: process.Monitor,
    finished: process.Subject(StopCompletion),
    progress: StopProgress,
  )
}

/// Which of the two stop signals (runtime drained, supervisor exited) have
/// arrived. Both-arrived is never stored: the second signal stops the actor.
type StopProgress {
  AwaitingBoth
  RuntimeStopAcknowledged
  SupervisorExited
}

type State {
  State(
    self_subject: process.Subject(Message),
    parent: process.Pid,
    supervisor: process.Pid,
    stop_state: StopState,
    inbox: work_queue.Queue(Message),
    stop_credit: Option(work_queue.Reservation),
    runtime_stopped: process.Subject(StopCompletion),
    stop_runtime: fn(process.Subject(StopCompletion)) ->
      Result(process.Monitor, Nil),
  )
}

/// Start a process that owns the nested supervisor and preserves the
/// distinction between intentional shutdown and restart-intensity exhaustion.
pub fn start(
  name: process.Name(Message),
  stop_runtime: fn(process.Subject(StopCompletion)) ->
    Result(process.Monitor, Nil),
  start_supervisor: fn() ->
    Result(actor.Started(static_supervisor.Supervisor), actor.StartError),
) -> Result(actor.Started(static_supervisor.Supervisor), actor.StartError) {
  let parent = process.self()

  actor.new_with_initialiser(5000, fn(subject) {
    process.trap_exits(True)
    case start_supervisor() {
      Error(error) -> Error(start_error_message(error))
      Ok(started) -> {
        let assert Ok(limits) = overload.limits(items: 1, bytes: 256)
        let inbox =
          work_queue.new(limits, overload.RouterQueue, False, fn() {
            process.send(subject, WorkAvailable)
          })
        work_queue.name(inbox, name)
        let _timer = process.send_after(subject, 100, RecoverWork)
        let runtime_stopped = process.new_subject()
        let selector =
          process.new_selector()
          |> process.select(subject)
          |> process.select_map(runtime_stopped, RuntimeStopped)
          |> process.select_monitors(RuntimeDown)
          |> process.select_trapped_exits(LinkedExit)

        actor.initialised(State(
          self_subject: subject,
          parent: parent,
          supervisor: started.pid,
          stop_state: Running,
          inbox: inbox,
          stop_credit: None,
          runtime_stopped: runtime_stopped,
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

/// Admit one stop request for this supervisor incarnation.
pub fn request_stop(
  name: process.Name(Message),
  finished: process.Subject(StopCompletion),
) -> Result(StopAcceptance, overload.CallError) {
  use queue <- result.try(
    work_queue.lookup(name) |> result.map_error(overload.AdmissionRejected),
  )
  work_queue.call(queue, 1000, fn(reply) { StopRuntime(reply, finished) })
}

fn clear_stop_credit(state: State) -> State {
  case state.stop_credit {
    Some(credit) -> work_queue.release(state.inbox, credit)
    None -> Nil
  }
  State(..state, stop_credit: None)
}

fn handle_stop_request(
  state: State,
  started: fn(StopAcceptance) -> Nil,
  finished: process.Subject(StopCompletion),
) -> actor.Next(State, Message) {
  case state.stop_runtime(state.runtime_stopped) {
    Error(Nil) -> {
      started(StopRejected)
      actor.continue(clear_stop_credit(state))
    }
    Ok(monitor) -> {
      started(StopAccepted)
      actor.continue(
        State(..state, stop_state: Stopping(monitor, finished, AwaitingBoth)),
      )
    }
  }
}

fn handle_message(
  state: State,
  message: Message,
) -> actor.Next(State, Message) {
  case message {
    WorkAvailable ->
      case work_queue.take(state.inbox) {
        Error(Nil) -> actor.continue(state)
        Ok(#(credit, request)) ->
          handle_message(State(..state, stop_credit: Some(credit)), request)
      }
    StopRuntime(started, _) if state.stop_state != Running -> {
      started(StopRejected)
      actor.continue(state)
    }
    StopRuntime(started, finished) ->
      handle_stop_request(state, started, finished)
    RecoverWork -> {
      let _timer = process.send_after(state.self_subject, 100, RecoverWork)
      handle_message(state, WorkAvailable)
    }
    RuntimeStopped(completion) ->
      case state.stop_state {
        Stopping(_, finished, SupervisorExited) -> {
          process.send(finished, completion)
          actor.stop()
        }
        Stopping(monitor, finished, AwaitingBoth) -> {
          process.send(finished, completion)
          actor.continue(
            State(
              ..state,
              stop_state: Stopping(monitor, finished, RuntimeStopAcknowledged),
            ),
          )
        }
        Running | Stopping(_, _, RuntimeStopAcknowledged) ->
          actor.continue(state)
      }
    RuntimeDown(down) -> handle_runtime_down(state, down)
    LinkedExit(process.ExitMessage(pid, _)) if pid == state.supervisor ->
      case state.stop_state {
        Stopping(_, _, RuntimeStopAcknowledged) -> actor.stop()
        Stopping(monitor, finished, AwaitingBoth) ->
          actor.continue(
            State(
              ..state,
              stop_state: Stopping(monitor, finished, SupervisorExited),
            ),
          )
        Running | Stopping(_, _, SupervisorExited) -> {
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

fn handle_runtime_down(
  state: State,
  down: process.Down,
) -> actor.Next(State, Message) {
  case down, state.stop_state {
    process.ProcessDown(monitor, _, _),
      Stopping(expected, finished, AwaitingBoth)
      if monitor == expected
    -> {
      process.send(finished, StopIncomplete)
      actor.continue(clear_stop_credit(State(..state, stop_state: Running)))
    }
    process.ProcessDown(monitor, _, _),
      Stopping(expected, finished, SupervisorExited)
      if monitor == expected
    -> {
      process.send(finished, StopIncomplete)
      process.trap_exits(False)
      actor.stop_abnormal("app subtree restart intensity exceeded")
    }
    process.ProcessDown(_, _, _), Running
    | process.ProcessDown(_, _, _), Stopping(_, _, RuntimeStopAcknowledged)
    | process.ProcessDown(_, _, _), Stopping(_, _, AwaitingBoth)
    | process.ProcessDown(_, _, _), Stopping(_, _, SupervisorExited)
    | process.PortDown(_, _, _), Running
    | process.PortDown(_, _, _), Stopping(_, _, _)
    -> actor.continue(state)
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
