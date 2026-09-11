-module(beryl_supervisor_test_ffi).
-export([get_subject_pid/1, crash_reason/0, active_child_count/1,
         only_active_child/1,
         gate_new/0, gate_wait/1, gate_release/1,
         connection_limit_checkpoint_heir/1,
         connection_limit_heir_stops_before_table/0,
         connection_limit_heir_stops_before_announcement/0]).

%% Extract the process that will receive messages for a subject.
%% For named subjects, the name is registered with the process.
get_subject_pid(Subject) ->
    case Subject of
        %% Named subject: {named_subject, Name}
        {named_subject, Name} ->
            case erlang:whereis(Name) of
                undefined -> {error, nil};
                Pid -> {ok, Pid}
            end;
        %% Regular subject: {subject, OwnerPid, _Tag}
        {subject, Pid, _} ->
            {ok, Pid}
    end.

%% Return an atom that serves as an abnormal exit reason
crash_reason() ->
    test_crash.

%% Number of children a supervisor currently owns. A dead supervisor owns
%% none, so a stopped socket factory reports zero rather than crashing.
active_child_count(Pid) ->
    try supervisor:count_children(Pid) of
        Counts -> proplists:get_value(active, Counts, 0)
    catch
        _:_ -> 0
    end.

only_active_child(Pid) ->
    case supervisor:which_children(Pid) of
        [{_, Child, _, _}] when is_pid(Child) -> {ok, Child};
        _ -> {error, nil}
    end.

connection_limit_checkpoint_heir(Limiter) ->
    Heirs = [ets:info(Table, heir)
             || Table <- ets:all(),
                ets:info(Table, name) =:= beryl_connection_limit_state,
                ets:info(Table, owner) =:= Limiter],
    case [Heir || Heir <- Heirs, is_pid(Heir)] of
        [Heir] -> {ok, Heir};
        _ -> {error, nil}
    end.

connection_limit_heir_stops_before_table() ->
    Supervisor = spawn(fun wait_for_stop/0),
    Key = {?MODULE, checkpoint_before_table, make_ref()},
    Heir = beryl_ffi:connection_limit_state_heir_start(Supervisor, Key),
    Monitor = erlang:monitor(process, Heir),
    try
        exit(Supervisor, kill),
        await_down(Monitor, Heir, checkpoint_heir_before_table),
        nil
    after
        exit(Heir, kill),
        exit(Supervisor, kill),
        persistent_term:erase(Key)
    end.

connection_limit_heir_stops_before_announcement() ->
    Supervisor = spawn(fun wait_for_stop/0),
    Key = {?MODULE, checkpoint_before_announcement, make_ref()},
    Heir = beryl_ffi:connection_limit_state_heir_start(Supervisor, Key),
    Parent = self(),
    Owner = spawn(fun() ->
        Table = ets:new(beryl_connection_limit_state,
                        [set, public, {heir, Heir, test}]),
        true = ets:insert(Table, {state, test}),
        persistent_term:put(Key, Table),
        Parent ! {checkpoint_table_ready, self()},
        wait_for_stop()
    end),
    HeirMonitor = erlang:monitor(process, Heir),
    OwnerMonitor = erlang:monitor(process, Owner),
    try
        receive
            {checkpoint_table_ready, Owner} -> ok
        after 1000 ->
            error(checkpoint_table_start_timeout)
        end,
        exit(Supervisor, kill),
        await_down(
            HeirMonitor, Heir, checkpoint_heir_before_announcement),
        undefined = persistent_term:get(Key, undefined),
        Owner ! stop,
        await_down(OwnerMonitor, Owner, checkpoint_table_owner),
        nil
    after
        exit(Owner, kill),
        exit(Heir, kill),
        exit(Supervisor, kill),
        persistent_term:erase(Key)
    end.

await_down(Monitor, Pid, Label) ->
    receive
        {'DOWN', Monitor, process, Pid, _Reason} -> ok
    after 1000 ->
        error({checkpoint_process_leaked, Label})
    end.

wait_for_stop() ->
    receive
        stop -> ok
    end.

gate_new() ->
    Gate = atomics:new(1, [{signed, false}]),
    atomics:put(Gate, 1, 0),
    Gate.

gate_wait(Gate) ->
    case atomics:get(Gate, 1) of
        1 -> nil;
        0 ->
            receive
            after 1 ->
                gate_wait(Gate)
            end
    end.

gate_release(Gate) ->
    atomics:put(Gate, 1, 1),
    nil.
