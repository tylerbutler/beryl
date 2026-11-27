//// Test-only host for the Bend protocol pilot. Both targets run the same traces
//// and retain the exact opaque capabilities delivered by the protocol.

import beryl_protocol as protocol
import gleam/dynamic
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result

type Host {
  Host(
    state: protocol.State,
    channels: List(protocol.Channel),
    joins: List(protocol.Operation(protocol.JoinKind)),
    admissions: List(protocol.Operation(protocol.AdmissionKind)),
    replies: List(protocol.Operation(protocol.ReplyKind)),
    cleanups: List(protocol.Operation(protocol.CleanupKind)),
  )
}

fn initial(epoch: String) -> Host {
  let assert Ok(state) = protocol.new(protocol.config(), epoch, 0)
  Host(state, [], [], [], [], [])
}

fn pick(local: List(a), foreign: List(a), command: Int) -> Result(a, Nil) {
  let handles = case command {
    command if command >= 20 -> foreign
    command if command >= 12 -> list.reverse(local)
    _ -> local
  }
  list.first(handles)
}

fn input(
  host: Host,
  foreign: Host,
  command: Int,
) -> Result(protocol.Input, Nil) {
  case command {
    0 ->
      Ok(
        protocol.Receive(protocol.Join(
          "room:pilot",
          dynamic.nil(),
          Some("join"),
          Some("join"),
        )),
      )
    1 | 12 | 20 -> {
      use operation <- result.map(pick(host.joins, foreign.joins, command))
      protocol.AcceptJoin(
        operation,
        json.null(),
        protocol.InvalidateImmediately,
      )
    }
    2 -> {
      use operation <- result.map(pick(host.joins, foreign.joins, command))
      protocol.AcceptJoin(operation, json.null(), protocol.DrainBeforeCleanup)
    }
    3 -> {
      use operation <- result.map(pick(host.joins, foreign.joins, command))
      protocol.RejectJoin(operation, json.null())
    }
    4 | 13 | 21 -> {
      use operation <- result.map(pick(
        host.admissions,
        foreign.admissions,
        command,
      ))
      protocol.AdmissionFinished(operation, True)
    }
    5 ->
      Ok(
        protocol.Receive(protocol.Message(
          "room:pilot",
          "command",
          dynamic.nil(),
          Some("join"),
          Some("request"),
        )),
      )
    6 | 14 | 22 -> {
      use operation <- result.map(pick(host.replies, foreign.replies, command))
      protocol.Reply(operation, protocol.StatusOk, json.null())
    }
    7 | 15 | 23 -> {
      use operation <- result.map(pick(host.replies, foreign.replies, command))
      protocol.Discard(operation)
    }
    8 | 16 | 24 -> {
      use channel <- result.map(pick(host.channels, foreign.channels, command))
      protocol.BeginClose(channel, protocol.Normal)
    }
    9 | 17 | 25 -> {
      use channel <- result.map(pick(host.channels, foreign.channels, command))
      protocol.Push(channel, "pushed", json.null())
    }
    10 | 18 | 26 -> {
      use operation <- result.map(pick(host.cleanups, foreign.cleanups, command))
      protocol.DrainFinished(operation, protocol.Normal)
    }
    11 | 19 | 27 -> {
      use operation <- result.map(pick(host.cleanups, foreign.cleanups, command))
      protocol.CleanupFinished(operation)
    }
    _ -> Error(Nil)
  }
}

fn retain(host: Host, action: protocol.Action) -> Host {
  case action {
    protocol.DeliverJoin(channel, operation, _, _) ->
      Host(..host, channels: [channel, ..host.channels], joins: [
        operation,
        ..host.joins
      ])
    protocol.AdmitJoin(_, operation, _) ->
      Host(..host, admissions: [operation, ..host.admissions])
    protocol.DeliverMessage(_, _, _, _, Some(operation)) ->
      Host(..host, replies: [operation, ..host.replies])
    protocol.CloseChannel(_, operation, _, _) ->
      Host(..host, cleanups: [operation, ..host.cleanups])
    protocol.DeliverMessage(_, _, _, _, None)
    | protocol.Joined(..)
    | protocol.Send(_)
    | protocol.CloseConnection(_)
    | protocol.Deadline(_) -> host
  }
}

fn apply(
  host: Host,
  foreign: Host,
  command: Int,
) -> #(Host, List(protocol.Action)) {
  case input(host, foreign, command) {
    Error(Nil) -> #(host, [])
    Ok(input) -> {
      let assert Ok(#(state, actions)) = protocol.step(host.state, input, 0)
      #(list.fold(actions, Host(..host, state: state), retain), actions)
    }
  }
}

fn action_name(action: protocol.Action) -> Result(String, Nil) {
  case action {
    protocol.DeliverJoin(..) -> Ok("deliver_join")
    protocol.AdmitJoin(..) -> Ok("admit_join")
    protocol.Joined(..) -> Ok("joined")
    protocol.DeliverMessage(..) -> Ok("deliver_message")
    protocol.CloseChannel(..) -> Ok("close_channel")
    protocol.CloseConnection(_) -> Ok("close_connection")
    protocol.Deadline(_) -> Error(Nil)
    protocol.Send(outbound) ->
      case outbound {
        protocol.ReplyMessage(_, Some("join"), _, protocol.StatusOk, _) ->
          Ok("join_ok")
        protocol.ReplyMessage(_, Some("join"), _, protocol.StatusError, _) ->
          Ok("join_error")
        protocol.ReplyMessage(_, _, _, protocol.StatusOk, _) -> Ok("reply_ok")
        protocol.ReplyMessage(_, _, _, protocol.StatusError, payload) ->
          Ok("error:" <> json.to_string(payload))
        protocol.PushMessage(..) -> Ok("pushed")
        protocol.TerminalMessage(..) -> Ok("terminal")
        protocol.HeartbeatReply(_) -> Ok("heartbeat")
      }
  }
}

fn observe(host: Host, actions: List(protocol.Action)) -> json.Json {
  json.object([
    #("pending", json.int(protocol.pending_count(host.state))),
    #(
      "joined",
      json.bool(result.is_ok(protocol.channel(host.state, "room:pilot"))),
    ),
    #(
      "pushable",
      json.bool(result.is_ok(protocol.push_channel(host.state, "room:pilot"))),
    ),
    #("actions", json.array(list.filter_map(actions, action_name), json.string)),
  ])
}

fn run(trace: List(Int), foreign: Host) -> json.Json {
  let #(_, observations) =
    list.fold(trace, #(initial("local"), []), fn(accumulator, command) {
      let #(host, actions) = apply(accumulator.0, foreign, command)
      #(host, [observe(host, actions), ..accumulator.1])
    })
  json.object([
    #("trace", json.array(trace, json.int)),
    #(
      "observations",
      json.array(list.reverse(observations), fn(value) { value }),
    ),
  ])
}

fn random_trace(remaining: Int, seed: Int) -> List(Int) {
  case remaining {
    0 -> []
    _ -> {
      let next = seed * 48_271 % 2_147_483_647
      [next % 28, ..random_trace(remaining - 1, next)]
    }
  }
}

fn traces() -> List(List(Int)) {
  let commands =
    int.range(0, 28, [], fn(accumulator, value) { [value, ..accumulator] })
  let pairs =
    list.flat_map(
      [[], [0], [0, 1], [0, 1, 4], [0, 2, 4, 5, 8], [0, 1, 4, 0]],
      fn(prefix) {
        list.flat_map(commands, fn(first) {
          list.map(commands, fn(second) { list.append(prefix, [first, second]) })
        })
      },
    )
  let focused = [
    [0, 1, 4, 5, 6, 5, 14, 6, 6],
    [0, 1, 4, 5, 7, 5, 15, 6],
    [0, 1, 4, 0, 11, 0, 12, 1, 4, 13, 4],
    [0, 2, 4, 5, 8, 9, 6, 10, 9, 6, 11],
    [0, 1, 4, 0, 11, 1, 4, 16, 17, 19, 9],
  ]
  let random =
    int.range(1, 65, [], fn(accumulator, seed) {
      [list.append([0, 1 + seed % 2, 4], random_trace(48, seed)), ..accumulator]
    })
  list.flatten([pairs, focused, random])
}

/// Print the shared trace corpus and observations for either compiler target.
pub fn main() -> Nil {
  let foreign =
    list.fold([0, 2, 4, 5, 8], initial("foreign"), fn(host, command) {
      apply(host, host, command).0
    })
  list.each(traces(), fn(trace) {
    run(trace, foreign) |> json.to_string |> io.println
  })
}
