-module(beryl_supervisor_test_ffi).
-export([get_subject_pid/1, crash_reason/0, active_child_count/1,
         only_active_child/1,
         gate_new/0, gate_wait/1, gate_release/1,
         with_suspended_subtree/2,
         connection_limit_checkpoint_table/1,
         connection_limit_checkpoint_heir/1,
         checkpoint_manager_sync/1]).

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

with_suspended_subtree(Factory, Action) ->
    {links, [Supervisor]} = process_info(Factory, links),
    {dictionary, Dictionary} = process_info(Supervisor, dictionary),
    [Ancestor | _] = proplists:get_value('$ancestors', Dictionary),
    Owner = case Ancestor of
        Name when is_atom(Name) -> whereis(Name);
        Pid when is_pid(Pid) -> Pid
    end,
    ok = sys:suspend(Supervisor),
    try Action(Supervisor, Owner)
    after ok = sys:resume(Supervisor)
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

%% Resolve the native ETS identity owned by this limiter with a live heir.
%% Neither the table's label nor its contents participate in discovery.
connection_limit_checkpoint_table(Limiter) ->
    case [Table || Table <- ets:all(),
                   checkpoint_table_matches(Table, Limiter)] of
        [Table] -> {ok, Table};
        _ -> {error, nil}
    end.

checkpoint_table_matches(Table, Limiter) ->
    try ets:info(Table) of
        undefined -> false;
        Metadata ->
            case {proplists:get_value(owner, Metadata),
                  proplists:get_value(heir, Metadata)} of
                {Limiter, Heir} when is_pid(Heir) ->
                    erlang:is_process_alive(Heir);
                _ -> false
            end
    catch
        error:badarg -> false
    end.

connection_limit_checkpoint_heir(Limiter) ->
    case connection_limit_checkpoint_table(Limiter) of
        {ok, Table} ->
            try ets:info(Table, heir) of
                Heir when is_pid(Heir) -> {ok, Heir};
                _ -> {error, nil}
            catch
                error:badarg -> {error, nil}
            end;
        {error, nil} -> {error, nil}
    end.

%% Process earlier messages from this caller before returning. Keep the
%% manager state private, and let OTP call failures fail the test.
checkpoint_manager_sync(Manager) ->
    _ = sys:get_state(Manager),
    nil.

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
