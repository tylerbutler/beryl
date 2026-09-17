-module(beryl_pubsub_test_ffi).
-export([is_scoped_wire_message/5, drain_messages/5,
         kill_scope/1, recovered/4, unmanaged_scope_rejected/1,
         during_outage/2, unavailable/1, kill_registry/1, scope_pid/1]).

scope_pid(Scope) -> whereis(Scope).

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
    Pid = beryl_pubsub_ffi:start_pg_scope(Scope),
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
    Rejected andalso is_pid(beryl_pubsub_ffi:start_pg_scope(Scope)).

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
