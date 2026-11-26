import Base
import ./model.bend as Model

# A capability from another connection cannot change state or emit actions.
law foreign_handles_are_noops:
  for +state: Model.State
  for +number: Nat
  for mode: Model.Mode
  {[Model.accept(Model.Foreign{number}, state, mode),
    Model.reject(Model.Foreign{number}, state),
    Model.admit(Model.Foreign{number}, state),
    Model.consume(Model.Foreign{number}, state, True{}),
    Model.consume(Model.Foreign{number}, state, False{}),
    Model.close(Model.Foreign{number}, state),
    Model.push(Model.Foreign{number}, state),
    Model.drain(Model.Foreign{number}, state),
    Model.cleanup(Model.Foreign{number}, state)]
    == List.replicate(Model.Output, 9n, Model.unchanged(state)) : List<&2, Model.Output>}

# This covers both reply and discard of the current pending capability.
law reply_capabilities_are_single_use:
  for +nc: Nat
  for +no: Nat
  for +phase: Model.Phase
  for +operation: Nat
  for +emit: Bool
  state = {Model.State{nc, no, phase, Model.PendingReply{operation}} : Model.State}
  {Model.actions(Model.consume(Model.Local{operation},
    Model.next(Model.consume(Model.Local{operation}, state, emit)), emit))
    == [] : List<&2, Model.Action>}

law empty_reply_ledger_is_a_noop:
  for +nc: Nat
  for +no: Nat
  for +phase: Model.Phase
  for handle: Model.Handle
  for emit: Bool
  state = {Model.State{nc, no, phase, Model.NoReply{}} : Model.State}
  {Model.consume(handle, state, emit) == Model.unchanged(state) : Model.Output}

# A new request may reuse its wire reference, but not the old operation identity.
law different_reply_capability_is_a_noop:
  for +nc: Nat
  for +no: Nat
  for +phase: Model.Phase
  for +pending: Nat
  for +wanted: Nat
  for +emit: Bool
  for different: {Nat.is_eq(wanted, pending) == False{} : Bool}
  state = {Model.State{nc, no, phase, Model.PendingReply{pending}} : Model.State}
  {Model.consume(Model.Local{wanted}, state, emit) == Model.unchanged(state) : Model.Output}

# Positive behavior prevents an implementation that drops every join from passing.
law authorization_requests_admission:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for +mode: Model.Mode
  {Model.accept(Model.Local{operation},
    Model.State{nc, no, Model.Authorizing{channel, operation}, Model.NoReply{}}, mode)
    == Model.Output{Model.State{nc, no, Model.Admitting{channel, operation, mode}, Model.NoReply{}},
      [Model.AdmitJoin{operation}]} : Model.Output}

law successful_admission_establishes_before_reply:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for +mode: Model.Mode
  {Model.admit(Model.Local{operation},
    Model.State{nc, no, Model.Admitting{channel, operation, mode}, Model.NoReply{}})
    == Model.Output{Model.State{nc, no, Model.Established{channel, mode}, Model.NoReply{}},
      [Model.Joined{}, Model.JoinOk{}]} : Model.Output}

law unadmitted_channels_cannot_push:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for +mode: Model.Mode
  for +handle: Model.Handle
  authorizing = {Model.State{nc, no, Model.Authorizing{channel, operation}, Model.NoReply{}} : Model.State}
  admitting = {Model.State{nc, no, Model.Admitting{channel, operation, mode}, Model.NoReply{}} : Model.State}
  {[Model.push(handle, authorizing), Model.push(handle, admitting)]
    == [Model.unchanged(authorizing), Model.unchanged(admitting)] : List<&2, Model.Output>}

law joins_wait_while_cleanup_is_pending:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for +mode: Model.Mode
  for +replacement: Bool
  for +pending: Model.Pending
  state = {Model.State{nc, no, Model.Closing{channel, operation, mode, replacement}, pending} : Model.State}
  {Model.join(state) == Model.unchanged(state) : Model.Output}

law cleanup_precedes_replacement_authorization:
  for +nc: Nat
  for +no: Nat
  for channel: Nat
  for +operation: Nat
  for mode: Model.Mode
  for pending: Model.Pending
  {Model.cleanup(Model.Local{operation},
    Model.State{nc, no, Model.Closing{channel, operation, mode, True{}}, pending})
    == Model.Output{Model.State{1n+nc, 1n+no, Model.Authorizing{nc, no}, Model.NoReply{}},
      [Model.Terminal{}, Model.DeliverJoin{nc, no}]} : Model.Output}

law completed_drain_invalidates_replies_and_pushes:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for mode: Model.Mode
  for +replacement: Bool
  for pending: Model.Pending
  {Model.drain(Model.Local{operation},
    Model.State{nc, no, Model.Closing{channel, operation, mode, replacement}, pending})
    == Model.Output{Model.State{nc, no,
      Model.Closing{channel, operation, Model.Immediate{}, replacement}, Model.NoReply{}}, []} : Model.Output}

law invalidated_closing_channels_cannot_push:
  for +nc: Nat
  for +no: Nat
  for +channel: Nat
  for +operation: Nat
  for +replacement: Bool
  for +pending: Model.Pending
  for handle: Model.Handle
  state = {Model.State{nc, no,
    Model.Closing{channel, operation, Model.Immediate{}, replacement}, pending} : Model.State}
  {Model.push(handle, state) == Model.unchanged(state) : Model.Output}
