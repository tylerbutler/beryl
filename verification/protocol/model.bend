import Base

type Handle is Data:
  Local{number: Nat}
  Foreign{number: Nat}

type Mode is Data:
  Immediate{}
  Drain{}

type Phase is Data:
  Vacant{}
  Authorizing{channel: Nat, operation: Nat}
  Admitting{channel: Nat, operation: Nat, mode: Mode}
  Established{channel: Nat, mode: Mode}
  Closing{channel: Nat, operation: Nat, mode: Mode, replacement: Bool}

type Pending is Data:
  NoReply{}
  PendingReply{operation: Nat}

type State is Data:
  State{next_channel: Nat, next_operation: Nat, phase: Phase, pending: Pending}

type Action is Data:
  DeliverJoin{channel: Nat, operation: Nat}
  AdmitJoin{operation: Nat}
  Joined{}
  JoinOk{}
  JoinError{}
  DeliverMessage{operation: Nat}
  DuplicateRef{}
  UnmatchedTopic{}
  ReplyOk{}
  CloseChannel{operation: Nat}
  Terminal{}
  Pushed{}

type Output is Data:
  Output{state: State, actions: List<&2, Action>}

def choose(-A: Data, flag: Bool, yes: A, no: A) -> A:
  match flag:
    case True{}: yes
    case False{}: no

def initial() -> State:
  State{1n, 1n, Vacant{}, NoReply{}}

def unchanged(state: State) -> Output:
  Output{state, []}

def next(output: Output) -> State:
  match output:
    case Output{state, _}: state

def actions(output: Output) -> List<&2, Action>:
  match output:
    case Output{_, actions}: actions

def pending_count(state: State) -> Nat:
  match state:
    case State{_, _, Authorizing{_, _}, _}: 1n
    case State{_, _, Admitting{_, _, _}, _}: 1n
    case State{_, _, _, NoReply{}}: 0n
    case State{_, _, _, PendingReply{_}}: 1n

def joined(state: State) -> Bool:
  match state:
    case State{_, _, Established{_, _}, _}: True{}
    case _: False{}

def pushable(state: State) -> Bool:
  match state:
    case State{_, _, Established{_, _}, _}: True{}
    case State{_, _, Closing{_, _, Drain{}, _}, _}: True{}
    case _: False{}

def begin_join(state: State) -> Output:
  match state:
    case State{+channel, +operation, _, _}:
      Output{State{1n+channel, 1n+operation, Authorizing{channel, operation}, NoReply{}},
        [DeliverJoin{channel, operation}]}

def append_actions(before: List<&2, Action>, output: Output) -> Output:
  match output:
    case Output{state, after}: Output{state, List.append(&2, Action, before, after)}

def is_drain(mode: Mode) -> Bool:
  match mode:
    case Immediate{}: False{}
    case Drain{}: True{}

def start_close(state: State, replacement: Bool) -> Output:
  match state:
    case State{nc, +operation, Established{channel, +mode}, pending}:
      Output{State{nc, 1n+operation, Closing{channel, operation, mode, replacement},
        choose(Pending, is_drain(mode), pending, NoReply{})}, [CloseChannel{operation}]}
    case _: unchanged(state)

def join(+state: State) -> Output:
  match state:
    case State{_, _, Vacant{}, _}: begin_join(state)
    case State{_, _, Authorizing{_, _}, _}: append_actions([JoinError{}], begin_join(state))
    case State{_, _, Admitting{_, _, _}, _}: append_actions([JoinError{}], begin_join(state))
    case State{_, _, Established{_, _}, _}: start_close(state, True{})
    case State{_, _, Closing{_, _, _, _}, _}: unchanged(state)

def accept(handle: Handle, +state: State, mode: Mode) -> Output:
  match handle state:
    case Local{wanted} State{nc, no, Authorizing{channel, +operation}, pending}:
      choose(Output, Nat.is_eq(wanted, operation),
        Output{State{nc, no, Admitting{channel, operation, mode}, pending}, [AdmitJoin{operation}]},
        unchanged(state))
    case _ _: unchanged(state)

def reject(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{nc, no, Authorizing{_, operation}, _}:
      choose(Output, Nat.is_eq(wanted, operation),
        Output{State{nc, no, Vacant{}, NoReply{}}, [JoinError{}]}, unchanged(state))
    case _ _: unchanged(state)

def admit(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{nc, no, Admitting{channel, operation, mode}, pending}:
      choose(Output, Nat.is_eq(wanted, operation),
        Output{State{nc, no, Established{channel, mode}, pending}, [Joined{}, JoinOk{}]},
        unchanged(state))
    case _ _: unchanged(state)

def request(+state: State) -> Output:
  match state:
    case State{nc, +operation, Established{channel, mode}, NoReply{}}:
      Output{State{nc, 1n+operation, Established{channel, mode}, PendingReply{operation}},
        [DeliverMessage{operation}]}
    case State{_, _, Established{_, _}, PendingReply{_}}:
      Output{state, [DuplicateRef{}]}
    case _: Output{state, [UnmatchedTopic{}]}

def consume_decision(+state: State, emit: Bool, matches: Bool) -> Output:
  match state matches:
    case State{nc, no, phase, _} True{}:
      Output{State{nc, no, phase, NoReply{}}, choose(List<&2, Action>, emit, [ReplyOk{}], [])}
    case _ False{}: unchanged(state)

def consume(handle: Handle, +state: State, emit: Bool) -> Output:
  match handle state:
    case Local{wanted} State{_, _, _, PendingReply{operation}}:
      consume_decision(state, emit, Nat.is_eq(wanted, operation))
    case _ _: unchanged(state)

def close(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{nc, no, Authorizing{channel, _}, _}:
      choose(Output, Nat.is_eq(wanted, channel),
        Output{State{nc, no, Vacant{}, NoReply{}}, [JoinError{}]}, unchanged(state))
    case Local{wanted} State{nc, no, Admitting{channel, _, _}, _}:
      choose(Output, Nat.is_eq(wanted, channel),
        Output{State{nc, no, Vacant{}, NoReply{}}, [JoinError{}]}, unchanged(state))
    case Local{wanted} State{_, _, Established{channel, _}, _}:
      choose(Output, Nat.is_eq(wanted, channel), start_close(state, False{}), unchanged(state))
    case _ _: unchanged(state)

def push(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{_, _, Established{channel, _}, _}:
      Output{state, choose(List<&2, Action>, Nat.is_eq(wanted, channel), [Pushed{}], [])}
    case Local{wanted} State{_, _, Closing{channel, _, Drain{}, _}, _}:
      Output{state, choose(List<&2, Action>, Nat.is_eq(wanted, channel), [Pushed{}], [])}
    case _ _: unchanged(state)

def drain(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{nc, no, Closing{channel, +operation, _, replacement}, _}:
      choose(Output, Nat.is_eq(wanted, operation),
        Output{State{nc, no, Closing{channel, operation, Immediate{}, replacement}, NoReply{}}, []},
        unchanged(state))
    case _ _: unchanged(state)

def cleanup(handle: Handle, +state: State) -> Output:
  match handle state:
    case Local{wanted} State{+nc, +no, Closing{_, operation, _, replacement}, _}:
      choose(Output, Nat.is_eq(wanted, operation),
        append_actions([Terminal{}], choose(Output, replacement,
          begin_join(State{nc, no, Vacant{}, NoReply{}}),
          unchanged(State{nc, no, Vacant{}, NoReply{}}))),
        unchanged(state))
    case _ _: unchanged(state)
