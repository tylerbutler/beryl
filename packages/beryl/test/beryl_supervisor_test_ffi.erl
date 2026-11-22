-module(beryl_supervisor_test_ffi).
-export([get_subject_pid/1, crash_reason/0, active_child_count/1,
         only_active_child/1,
         gate_new/0, gate_wait/1, gate_release/1,
         with_suspended_subtree/2,
         connection_limit_checkpoint_table/1,
         connection_limit_with_faulted_checkpoint/5,
         connection_limit_checkpoint_heir/1]).

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

%% Resolve the native ETS identity in this limiter's supervisor generation.
%% Neither the table's label nor its contents participate in discovery.
connection_limit_checkpoint_table(Limiter) ->
    case process_info(Limiter, [registered_name, dictionary]) of
        [{registered_name, Name}, {dictionary, Dictionary}] when is_atom(Name) ->
            case proplists:get_value('$ancestors', Dictionary) of
                [Supervisor | _] when is_pid(Supervisor) ->
                    Key = beryl_ffi:connection_limit_checkpoint_registry_key(
                        Supervisor, Name),
                    case beryl_ffi:connection_limit_checkpoint_registry_get(Key) of
                        {some, Table} ->
                            case ets:info(Table, owner) of
                                Limiter -> {ok, Table};
                                _ -> {error, nil}
                            end;
                        none -> {error, nil}
                    end;
                _ -> {error, nil}
            end;
        _ -> {error, nil}
    end.

connection_limit_checkpoint_heir(Limiter) ->
    case connection_limit_checkpoint_table(Limiter) of
        {ok, Table} ->
            case ets:info(Table, heir) of
                Heir when is_pid(Heir) -> {ok, Heir};
                _ -> {error, nil}
            end;
        {error, nil} -> {error, nil}
    end.

%% The worker is dead and replacement starts remain gated. Leave the original
%% with its real heir; the caller owns this unnamed clone throughout Action.
%% Copy the exact native row without exposing the private state type to Gleam.
connection_limit_with_faulted_checkpoint(Supervisor, Name, Original, Fault, Action) ->
    Key = beryl_ffi:connection_limit_checkpoint_registry_key(Supervisor, Name),
    {some, Original} = beryl_ffi:connection_limit_checkpoint_registry_get(Key),
    Clone = ets:new(connection_limit_checkpoint_fixture, [set, public]),
    try
        [{<<"state">>, _} = Row] = ets:lookup(Original, <<"state">>),
        true = ets:insert(Clone, Row),
        {some, Original} = beryl_ffi:connection_limit_checkpoint_registry_get(Key),
        nil = beryl_ffi:connection_limit_checkpoint_registry_put(Key, Clone),
        case Fault of
            deleted_checkpoint -> true = ets:delete(Clone);
            missing_checkpoint_state -> true = ets:delete(Clone, <<"state">>);
            unreadable_checkpoint -> true = ets:setopts(Clone, {protection, private})
        end,
        Action()
    after
        %% Also clean up if copying or fault setup failed before Action.
        try
            case beryl_ffi:connection_limit_checkpoint_registry_get(Key) of
                {some, Clone} ->
                    nil = beryl_ffi:connection_limit_checkpoint_registry_put(
                        Key, Original);
                {some, Original} -> ok;
                Unexpected ->
                    erlang:error({checkpoint_registry_changed, Unexpected})
            end
        after
            case ets:info(Clone) of
                undefined -> ok;
                _ -> true = ets:delete(Clone)
            end
        end
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
