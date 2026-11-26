import Base
import ./model.bend as Model
import ./LAWS.bend as Laws

def nat_same(+number: Nat) -> {Nat.is_eq(number, number) == True{} : Bool}:
  match number:
    case 0n: {==}
    case 1n+previous: nat_same(previous)

def Laws.foreign_handles_are_noops(state, number, mode):
  {==}

def successful_consume(+nc: Nat, +no: Nat, +phase: Model.Phase, +operation: Nat, +emit: Bool) ->
  {Model.consume(Model.Local{operation}, Model.State{nc, no, phase, Model.PendingReply{operation}}, emit)
    == Model.Output{Model.State{nc, no, phase, Model.NoReply{}},
      Model.choose(List<&2, Model.Action>, emit, [Model.ReplyOk{}], [])} : Model.Output}:
  state = {Model.State{nc, no, phase, Model.PendingReply{operation}} : Model.State}
  Equal.cong(Bool, Model.Output, matches => Model.consume_decision(state, emit, matches),
    Nat.is_eq(operation, operation), True{}, nat_same(operation))

def Laws.reply_capabilities_are_single_use(nc, no, phase, operation, emit):
  state = {Model.State{nc, no, phase, Model.PendingReply{operation}} : Model.State}
  cleared = {Model.Output{Model.State{nc, no, phase, Model.NoReply{}},
    Model.choose(List<&2, Model.Action>, emit, [Model.ReplyOk{}], [])} : Model.Output}
  Equal.cong(Model.Output, List<&2, Model.Action>,
    output => Model.actions(Model.consume(Model.Local{operation}, Model.next(output), emit)),
    Model.consume(Model.Local{operation}, state, emit), cleared,
    successful_consume(nc, no, phase, operation, emit))

def Laws.empty_reply_ledger_is_a_noop(nc, no, phase, handle, emit):
  match handle:
    case Model.Local{_}: {==}
    case Model.Foreign{_}: {==}

def Laws.different_reply_capability_is_a_noop(nc, no, phase, pending, wanted, emit, different):
  state = {Model.State{nc, no, phase, Model.PendingReply{pending}} : Model.State}
  Equal.cong(Bool, Model.Output, matches => Model.consume_decision(state, emit, matches),
    Nat.is_eq(wanted, pending), False{}, different)

def Laws.authorization_requests_admission(nc, no, channel, operation, mode):
  state = {Model.State{nc, no, Model.Authorizing{channel, operation}, Model.NoReply{}} : Model.State}
  success = {Model.Output{Model.State{nc, no, Model.Admitting{channel, operation, mode}, Model.NoReply{}},
    [Model.AdmitJoin{operation}]} : Model.Output}
  Equal.cong(Bool, Model.Output, matches => Model.choose(Model.Output, matches, success, Model.unchanged(state)),
    Nat.is_eq(operation, operation), True{}, nat_same(operation))

def Laws.successful_admission_establishes_before_reply(nc, no, channel, operation, mode):
  state = {Model.State{nc, no, Model.Admitting{channel, operation, mode}, Model.NoReply{}} : Model.State}
  success = {Model.Output{Model.State{nc, no, Model.Established{channel, mode}, Model.NoReply{}},
    [Model.Joined{}, Model.JoinOk{}]} : Model.Output}
  Equal.cong(Bool, Model.Output, matches => Model.choose(Model.Output, matches, success, Model.unchanged(state)),
    Nat.is_eq(operation, operation), True{}, nat_same(operation))

def Laws.unadmitted_channels_cannot_push(nc, no, channel, operation, mode, handle):
  match handle:
    case Model.Local{_}: {==}
    case Model.Foreign{_}: {==}

def Laws.joins_wait_while_cleanup_is_pending(nc, no, channel, operation, mode, replacement, pending):
  {==}

def Laws.cleanup_precedes_replacement_authorization(nc, no, channel, operation, mode, pending):
  state = {Model.State{nc, no, Model.Closing{channel, operation, mode, True{}}, pending} : Model.State}
  success = {Model.Output{Model.State{1n+nc, 1n+no, Model.Authorizing{nc, no}, Model.NoReply{}},
    [Model.Terminal{}, Model.DeliverJoin{nc, no}]} : Model.Output}
  Equal.cong(Bool, Model.Output, matches => Model.choose(Model.Output, matches, success, Model.unchanged(state)),
    Nat.is_eq(operation, operation), True{}, nat_same(operation))

def Laws.completed_drain_invalidates_replies_and_pushes(nc, no, channel, operation, mode, replacement, pending):
  state = {Model.State{nc, no, Model.Closing{channel, operation, mode, replacement}, pending} : Model.State}
  success = {Model.Output{Model.State{nc, no,
    Model.Closing{channel, operation, Model.Immediate{}, replacement}, Model.NoReply{}}, []} : Model.Output}
  Equal.cong(Bool, Model.Output, matches => Model.choose(Model.Output, matches, success, Model.unchanged(state)),
    Nat.is_eq(operation, operation), True{}, nat_same(operation))

def Laws.invalidated_closing_channels_cannot_push(nc, no, channel, operation, replacement, pending, handle):
  match handle:
    case Model.Local{_}: {==}
    case Model.Foreign{_}: {==}
