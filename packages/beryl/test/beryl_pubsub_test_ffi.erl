-module(beryl_pubsub_test_ffi).
-export([is_scoped_wire_message/5, drain_messages/5,
         kill_scope/1, recovered/4, unmanaged_scope_rejected/1,
         during_outage/2, kill_registry/1, scope_pid/1,
         healthy_ready_reductions/2, timeout_call_cleans_up/1,
         with_malformed_messages/2, with_suspended_registry/2,
         membership_intent_size/1, nonlocal_leave_preserves_registry/1,
         call_target/1, operation_failure/1, with_unmanaged_scope/2,
         with_unreconciled_scope/2]).

with_unreconciled_scope(Scope, Action) ->
    with_suspended_registry(Scope, fun(_RegistryPid) ->
        OldPid = kill_scope(Scope),
        Deadline = erlang:monotonic_time(millisecond) + 5000,
        NewPid = await_restarted_scope(Scope, OldPid, Deadline),
        %% The new pg has finished init but cannot have replayed local intent:
        %% the original registry is suspended with its old readiness marker.
        _ = sys:get_state(NewPid, 1000),
        [] = pg:get_local_members(Scope, <<"room:unreconciled">>),
        Action()
    end).

await_restarted_scope(Scope, OldPid, Deadline) ->
    case whereis(Scope) of
        Pid when is_pid(Pid), Pid =/= OldPid -> Pid;
        _ ->
            case erlang:monotonic_time(millisecond) < Deadline of
                true ->
                    receive after 1 -> ok end,
                    await_restarted_scope(Scope, OldPid, Deadline);
                false -> error(scope_did_not_restart)
            end
    end.

%% Test targets speak exactly the Subject(Subject(Nil)) protocol. A crashing
%% target exits only after receiving the request, exercising the DOWN branch.
call_target(<<"down">>) ->
    Pid = spawn(fun() ->
        receive {call_test, _Reply} ->
            exit({test_call_failure, 42, <<"original">>})
        end
    end),
    {subject, Pid, call_test};
call_target(<<"success">>) ->
    Pid = spawn(fun() ->
        receive {call_test, Reply} ->
            'gleam@erlang@process':send(Reply, nil)
        end
    end),
    {subject, Pid, call_test}.

operation_failure(<<"large">>) ->
    {native_failure, lists:duplicate(10000, <<"details">>)};
operation_failure(<<"unicode">>) ->
    %% Printable under both default latin1 and +pc unicode; ~tP legitimately
    %% renders CJK charlists as integer lists under the default printable range.
    {native_failure, [$c, $a, $f, 16#00E9]}.

with_unmanaged_scope(Scope, Action) ->
    {ok, Pid} = pg:start(Scope),
    try Action()
    after gen_server:stop(Pid)
    end.

start_ready(Scope) ->
    {ok, Registry} = beryl_pubsub_ffi:start_pg_scope(Scope),
    {ok, nil} = 'beryl@pubsub_membership':ready(Registry),
    Registry.

with_suspended_registry(Scope, Action) ->
    Registry = start_ready(Scope),
    Pid = 'beryl@pubsub_membership':pid(Registry),
    true = erlang:suspend_process(Pid),
    try Action(Pid)
    after erlang:resume_process(Pid)
    end.

membership_intent_size(Owner) ->
    lists:sum([ets:info(Table, size) || Table <- ets:all(),
        ets:info(Table, name) =:= beryl_pubsub_ffi,
        ets:info(Table, owner) =:= Owner]).

nonlocal_leave_preserves_registry(Scope) ->
    Registry = start_ready(Scope),
    RegistryPid = 'beryl@pubsub_membership':pid(Registry),
    {ok, Peer, _Node} = peer:start_link(#{
        name => peer:random_name("beryl_leave"),
        connection => standard_io,
        args => ["+S", "2:2"]
    }),
    try
        RemoteOwner = peer:call(Peer, erlang, whereis, [init]),
        {error, owner_not_local} = 'beryl@pubsub_membership':leave(
            Registry, <<"room:remote">>, RemoteOwner),
        {ok, nil} = 'beryl@pubsub_membership':ready(Registry),
        {ok, nil} = 'beryl@pubsub_membership':join(
            Registry, <<"room:healthy">>, self()),
        {ok, Instance} = 'beryl@pubsub':start(
            'beryl@pubsub':config_with_scope(atom_to_binary(Scope))),
        {ok, nil} = 'beryl@pubsub':broadcast(
            Instance, <<"room:healthy">>, <<"ok">>, nil),
        receive {Scope, <<"room:healthy">>, <<"ok">>, nil, system} -> ok
        after 1000 -> error(healthy_delivery_failed)
        end,
        RegistryPid = 'beryl@pubsub_membership':pid(
            start_ready(Scope)),
        {ok, nil} = 'beryl@pubsub_membership':leave(
            Registry, <<"room:healthy">>, self()),
        true
    after peer:stop(Peer)
    end.

with_malformed_messages(Scope, Receive) ->
    Messages = [
        {Scope},
        {Scope, <<"scope:malformed">>, <<"short">>, <<"payload">>},
        {Scope, <<"scope:malformed">>, <<"long">>, <<"payload">>, system, extra},
        {message, <<"scope:malformed">>, <<"legacy">>, <<"payload">>, system},
        {test_pubsub_other_ingress_scope, <<"scope:malformed">>,
         <<"wrong_scope">>, 42, system}
    ],
    lists:foreach(fun(Message) -> self() ! Message end, Messages),
    Receive(),
    Remaining = [receive Message -> true after 0 -> false end || Message <- Messages],
    lists:all(fun(Found) -> Found end, Remaining).

scope_pid(Scope) -> whereis(Scope).

healthy_ready_reductions(Scope, OwnerCount) ->
    Registry = start_ready(Scope),
    Owners = [spawn(fun owner_loop/0) || _ <- lists:seq(1, OwnerCount)],
    lists:foreach(fun({Owner, Index}) ->
        {ok, nil} = 'beryl@pubsub_membership':join(
            Registry, integer_to_binary(Index), Owner)
    end, lists:zip(Owners, lists:seq(1, OwnerCount))),
    RegistryPid = 'beryl@pubsub_membership':pid(Registry),
    {reductions, Before} = process_info(RegistryPid, reductions),
    {ok, nil} = 'beryl@pubsub_membership':ready(Registry),
    {reductions, After} = process_info(RegistryPid, reductions),
    OwnerMonitors = [{Owner, monitor(process, Owner)} || Owner <- Owners],
    lists:foreach(fun(Owner) -> Owner ! stop end, Owners),
    lists:foreach(fun({Owner, Monitor}) ->
        receive {'DOWN', Monitor, process, Owner, normal} -> ok end
    end, OwnerMonitors),
    wait_until_idle(RegistryPid),
    After - Before.

timeout_call_cleans_up(Scope) ->
    Registry = start_ready(Scope),
    RegistryPid = 'beryl@pubsub_membership':pid(Registry),
    Parent = self(),
    Worker = spawn(fun() ->
        {monitors, BeforeMonitors} = process_info(self(), monitors),
        true = erlang:suspend_process(RegistryPid),
        try
            {error, {call_failed, call_timed_out}} =
                'beryl@pubsub_membership':ready(Registry)
        after
            erlang:resume_process(RegistryPid)
        end,
        {ok, nil} = 'beryl@pubsub_membership':ready(Registry),
        {monitors, AfterMonitors} = process_info(self(), monitors),
        {messages, Messages} = process_info(self(), messages),
        Parent ! {self(), BeforeMonitors =:= AfterMonitors andalso Messages =:= []}
    end),
    receive
        {Worker, Clean} -> Clean
    after 6000 ->
        false
    end.

owner_loop() ->
    receive stop -> ok end.

wait_until_idle(Pid) ->
    case process_info(Pid, message_queue_len) of
        {message_queue_len, 0} -> ok;
        {message_queue_len, _} ->
            timer:sleep(1),
            wait_until_idle(Pid)
    end.

during_outage(Scope, Operation) ->
    {dictionary, Dictionary} = process_info(whereis(Scope), dictionary),
    [Supervisor | _] = proplists:get_value('$ancestors', Dictionary),
    ok = sys:suspend(Supervisor),
    try
        OldPid = kill_scope(Scope),
        Operation(),
        OldPid
    after
        ok = sys:resume(Supervisor)
    end.

kill_registry(Scope) ->
    Registry = start_ready(Scope),
    Pid = 'beryl@pubsub_membership':pid(Registry),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, killed} -> nil
    after 5000 -> error(registry_did_not_stop)
    end.

kill_scope(Scope) ->
    Pid = whereis(Scope),
    Ref = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Ref, process, Pid, killed} -> Pid
    after 5000 -> error(scope_did_not_stop)
    end.

recovered(Scope, OldPid, Topic, Count) ->
    Pid = whereis(Scope),
    is_pid(Pid) andalso Pid =/= OldPid andalso
        length(pg:get_local_members(Scope, Topic)) =:= Count.

unmanaged_scope_rejected(Scope) ->
    {ok, Pid} = pg:start(Scope),
    Rejected = try
        {error, _Reason} = beryl_pubsub_ffi:start_pg_scope(Scope),
        is_process_alive(Pid)
    after
        gen_server:stop(Pid)
    end,
    Registry = start_ready(Scope),
    Rejected andalso
        is_pid('beryl@pubsub_membership':pid(Registry)).

drain_messages(Scope, Topic, Event, Payload, From) ->
    drain_messages(Scope, Topic, Event, Payload, From, 0).

drain_messages(Scope, Topic, Event, Payload, From, Count) ->
    receive
        {Scope, Topic, Event, Payload, From} ->
            drain_messages(Scope, Topic, Event, Payload, From, Count + 1)
    after 0 ->
        Count
    end.

is_scoped_wire_message(Scope, Topic, Event, Payload, Timeout) ->
    receive
        {Scope, Topic, Event, Payload, system} -> true;
        {message, Topic, Event, Payload, system} -> false
    after Timeout ->
        false
    end.
