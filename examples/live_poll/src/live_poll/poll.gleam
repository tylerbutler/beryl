import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/json
import gleam/result

pub type Choice {
  Gleam
  Erlang
}

pub type Status {
  Open
  Closed
}

pub type Poll {
  Poll(gleam_votes: Int, erlang_votes: Int, status: Status)
}

pub type VoteError {
  PollClosed
}

pub type CloseResult {
  ClosedNow(Poll)
  AlreadyClosed(Poll)
}

pub type Command {
  GetState
  Vote(Choice)
  Close
  Unsupported
}

pub type CommandError {
  UnknownEvent(String)
  InvalidChoice
}

pub fn new() -> Poll {
  Poll(gleam_votes: 0, erlang_votes: 0, status: Open)
}

pub fn command(event: String, payload: Dynamic) -> Command {
  decode_command(event, payload) |> result.unwrap(Unsupported)
}

/// Decode client events for the typed channel; raw tutorial steps keep `command`.
pub fn decode_command(
  event: String,
  payload: Dynamic,
) -> Result(Command, CommandError) {
  case event {
    "get_state" -> Ok(GetState)
    "close_poll" -> Ok(Close)
    "vote" -> {
      let option = {
        use value <- decode.field("option", decode.string)
        decode.success(value)
      }
      case decode.run(payload, option) {
        Ok("gleam") -> Ok(Vote(Gleam))
        Ok("erlang") -> Ok(Vote(Erlang))
        Ok(_) | Error(_) -> Error(InvalidChoice)
      }
    }
    _ -> Error(UnknownEvent(event))
  }
}

pub fn vote(poll: Poll, choice: Choice) -> Result(Poll, VoteError) {
  case poll.status, choice {
    Closed, Gleam | Closed, Erlang -> Error(PollClosed)
    Open, Gleam -> Ok(Poll(..poll, gleam_votes: poll.gleam_votes + 1))
    Open, Erlang -> Ok(Poll(..poll, erlang_votes: poll.erlang_votes + 1))
  }
}

pub fn close(poll: Poll) -> CloseResult {
  case poll.status {
    Open -> ClosedNow(Poll(..poll, status: Closed))
    Closed -> AlreadyClosed(poll)
  }
}

pub fn to_json(poll: Poll) -> json.Json {
  json.object([
    #("question", json.string("Which BEAM language are you using today?")),
    #("gleam", json.int(poll.gleam_votes)),
    #("erlang", json.int(poll.erlang_votes)),
    #("open", json.bool(poll.status == Open)),
  ])
}

pub fn error_to_json(error: VoteError) -> json.Json {
  case error {
    PollClosed -> json.object([#("reason", json.string("poll_closed"))])
  }
}
