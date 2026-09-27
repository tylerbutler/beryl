-module(beryl_pubsub_test_ffi).
-export([is_scoped_wire_message/5, drain_messages/5,
         kill_scope/1, recovered/4, unmanaged_scope_rejected/1,
         during_outage/2, unavailable/1, kill_registry/1, scope_pid/1,
         healthy_ready_reductions/2, timeout_call_cleans_up/1,
         with_malformed_messages/2]).

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
    Registry = beryl_pubsub_ffi:start_pg_scope(Scope),
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
    Registry = beryl_pubsub_ffi:start_pg_scope(Scope),
    RegistryPid = 'beryl@pubsub_membership':pid(Registry),
    Parent = self(),
    Worker = spawn(fun() ->
        {monitors, BeforeMonitors} = process_info(self(), monitors),
        true = erlang:suspend_process(RegistryPid),
        try
            try 'beryl@pubsub_membership':ready(Registry)
            catch _:_ -> ok
            end
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

unavailable(Operation) ->
    try Operation(), false
    catch
        exit:{pubsub_unavailable, _Scope, _Reason} -> true;
        exit:{pubsub_start_failed, _Scope, _Reason} -> true;
        exit:{noproc, {gen_server, call, _Args}} -> true
    end.

kill_registry(Scope) ->
    Registry = beryl_pubsub_ffi:start_pg_scope(Scope),
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
        beryl_pubsub_ffi:start_pg_scope(Scope),
        false
    catch
        exit:{pubsub_start_failed, Scope, _Reason} ->
            is_process_alive(Pid)
    after
        gen_server:stop(Pid)
    end,
    Registry = beryl_pubsub_ffi:start_pg_scope(Scope),
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
