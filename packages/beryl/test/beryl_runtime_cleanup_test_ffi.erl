-module(beryl_runtime_cleanup_test_ffi).
-export([reductions/1, target_present/2, router_queue/1, with_root/2,
         with_full_router/2, down_pending/2, metadata/0, assert_monitor_index/2]).

%% Regression-only full-state inspection, NEVER a measurement barrier.
%% Match the private State's exact tag/arity (23 fields), final role field,
%% RouterRole's four fields, and SocketActorRef's nine fields. No state or
%% invented custom type crosses back to Gleam: success is exactly nil.
-spec assert_monitor_index(pid(), [{binary(), pid()}]) -> nil.
assert_monitor_index(Router, ExpectedActors) ->
    State = sys:get_state(Router, 1000),
    true = is_tuple(State) andalso tuple_size(State) =:= 24
        andalso element(1, State) =:= state,
    {router_role, Actors, Monitors, _StopReply, _StopFinalized} = element(24, State),
    true = is_map(Actors) andalso is_map(Monitors),
    Expected = maps:from_list(ExpectedActors),
    true = map_size(Expected) =:= length(ExpectedActors),
    true = map_size(Actors) =:= map_size(Expected),
    RequiredMonitors = maps:fold(fun(Id, ActorRef, Acc) ->
        {socket_actor_ref, _Subject, Pid, ActorMonitor, AdmissionMonitor,
         _Admission, _Close, _Queue, _Topics, _ConnectedAt} = ActorRef,
        true = is_binary(Id) andalso is_pid(Pid)
            andalso is_reference(ActorMonitor) andalso is_reference(AdmissionMonitor)
            andalso ActorMonitor =/= AdmissionMonitor,
        {ok, Pid} = maps:find(Id, Expected),
        Acc#{ActorMonitor => Id, AdmissionMonitor => Id}
    end, #{}, Actors),
    %% Cardinality also detects references accidentally shared across actors.
    true = map_size(RequiredMonitors) =:= 2 * map_size(Actors),
    case Monitors =:= RequiredMonitors of
        true -> nil;
        false -> error({socket_monitor_index_mismatch, RequiredMonitors, Monitors})
    end.

%% These are test failures, not recoverable application errors. A dead router
%% must never be represented as a successful zero-reduction sample.
-spec reductions(pid()) -> non_neg_integer().
reductions(Pid) ->
    {reductions, Count} = process_info(Pid, reductions),
    Count.

%% Read ONE target row, not the queue ledger or the router's global state.
%% The caller captures this queue before the measured interval.
-spec target_present(tuple(), binary()) -> boolean().
target_present({Table, _, _, _, _, _, _}, Id) ->
    ets:member(Table, {target, Id}).

-spec router_queue(pid()) -> tuple().
router_queue(Router) ->
    {registered_name, Name} = process_info(Router, registered_name),
    {ok, Queue = {_, Router, _, _, _, _, _}} =
        beryl_work_queue_ffi:lookup(Name),
    Queue.

%% Gleam owns the fixture model and drives all lifecycle operations. The root
%% remains linked to the isolated caller, including if that caller is killed.
-spec with_root(pid(), fun(() -> T)) -> T.
with_root(Root, Action) ->
    try Action()
    after
        ok = gen_server:stop(Root, normal, 10000)
    end.

%% Fault injection is ONLY admission pressure: no router/topic/reverse-index
%% corruption. Retained values fill the real queue's item budget. The test
%% publishes a real leave to the socket queue while this router is suspended.
%% The rejected IndexLeave increments the real queue's rejection counter.
-spec with_full_router(tuple(), fun(() -> T)) -> T.
with_full_router(Queue = {_, Router, Items, _, _, _, _}, Action) ->
    beryl_router_ownership_test_ffi:with_suspended(Router, fun() ->
        Reservations = reserve_all(Queue, Items, []),
        try Action()
        after
            lists:foreach(fun(Id) ->
                nil = beryl_work_queue_ffi:release(Queue, Id)
            end, Reservations)
        end
    end).

reserve_all(_, 0, Acc) -> Acc;
reserve_all(Queue, Remaining, Acc) ->
    case beryl_work_queue_ffi:retain(Queue, nil) of
        {ok, Id} -> reserve_all(Queue, Remaining - 1, [Id | Acc]);
        Failure ->
            lists:foreach(fun(Id) ->
                nil = beryl_work_queue_ffi:release(Queue, Id)
            end, Acc),
            error({cleanup_fixture_queue_not_idle, Failure})
    end.

%% Bounded regression-only mailbox inspection, never used for measurements.
%% Match the actual OTP signal, not a subject or an arbitrary queued message.
-spec down_pending(pid(), pid()) -> boolean().
down_pending(Router, Actor) ->
    {messages, Messages} = process_info(Router, messages),
    lists:any(fun
        ({'DOWN', Ref, process, Pid, _}) when is_reference(Ref), Pid =:= Actor ->
            true;
        (_) -> false
    end, Messages).

%% Return primitive tuples, not an identity conversion into a Gleam record.
%% CPU model/hardware notes and actual compiler version are supplied in the
%% typed fixture config: BEAM cannot discover the invoking Gleam executable.
-spec metadata() -> {binary(), binary(), binary(), binary(), integer(), integer(),
                     integer(), integer()}.
metadata() ->
    {Family, OS} = os:type(),
    %% Keep the OS variant in the architecture field without shelling out.
    {VM, OTP, Architecture, OSFamily, Schedulers, Online, Logical, WordBytes} =
        {list_to_binary(erlang:system_info(system_version)),
         list_to_binary(erlang:system_info(otp_release)),
         list_to_binary(erlang:system_info(system_architecture)),
         atom_to_binary(Family, utf8),
         erlang:system_info(schedulers),
         erlang:system_info(schedulers_online),
         logical_processors(),
         erlang:system_info(wordsize)},
    {VM, OTP, <<Architecture/binary, " / ", (atom_to_binary(OS, utf8))/binary>>,
     OSFamily, Schedulers, Online, Logical, WordBytes}.

logical_processors() ->
    case erlang:system_info(logical_processors_available) of
        Count when is_integer(Count), Count >= 0 -> Count;
        unknown -> -1
    end.
