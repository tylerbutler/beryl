-module(beryl_ffi).
-export([identity/1,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         connection_limit_call/3, connection_limit_send/2,
         connection_limit_state_open/2, connection_limit_state_put/2,
         connection_limit_state_heir_start/2]).

%% Used only after a selector validates the frozen raw PubSub record shape.
identity(X) -> X.

%% Run a callback, converting any crash (error/exit/throw) into an
%% {error, Description} result so a crashing callback cannot take down the
%% runtime actor running it. The description is depth-limited and truncated so
%% client-triggered crashes cannot bloat log metadata.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason ->
            Formatted = unicode:characters_to_binary(
                io_lib:format(
                    "~p:~P", [Class, Reason, 10], [{chars_limit, 512}])),
            {error, binary:copy(string:slice(Formatted, 0, 512))}
    end.

%% Deactivating the reply alias drops responses that arrive after this call
%% returns, while the monitor reports limiter death without waiting for timeout.
connection_limit_call(Subject, Timeout, Request) ->
    case connection_limit_subject_owner(Subject) of
        undefined ->
            {error, call_owner_unavailable};
        Owner ->
            Alias = erlang:alias([reply]),
            Tag = make_ref(),
            Reply = {subject, Alias, Tag},
            Monitor = erlang:monitor(process, Owner),
            try
                Owner ! connection_limit_subject_message(
                    Subject, Request(Reply)),
                receive
                    {Tag, Value} -> {ok, Value};
                    {'DOWN', Monitor, process, Owner, _Reason} ->
                        {error, call_owner_unavailable}
                after max(0, Timeout) ->
                    {error, call_timed_out}
                end
            after
                erlang:demonitor(Monitor, [flush]),
                erlang:unalias(Alias),
                receive {Tag, _} -> ok after 0 -> ok end
            end
    end.

connection_limit_send(Subject, Message) ->
    case connection_limit_subject_owner(Subject) of
        undefined -> false;
        Owner ->
            Owner ! connection_limit_subject_message(Subject, Message),
            true
    end.

connection_limit_subject_owner({subject, Owner, _Tag}) ->
    case is_process_alive(Owner) of
        true -> Owner;
        false -> undefined
    end;
connection_limit_subject_owner({named_subject, Name}) ->
    whereis(Name).

connection_limit_subject_message({subject, _Owner, Tag}, Message) ->
    {Tag, Message};
connection_limit_subject_message({named_subject, Name}, Message) ->
    {Name, Message}.

%% Keep admission state in ETS across limiter worker replacement. The
%% supervisor pid scopes the checkpoint to one subtree incarnation, and the
%% heir owns an inherited table only until that supervisor exits.
connection_limit_state_open(Key, InitialState) ->
    Supervisor = connection_limit_supervisor(),
    PersistentKey = {?MODULE, connection_limit_state, Supervisor, Key},
    case persistent_term:get(PersistentKey, undefined) of
        undefined ->
            connection_limit_state_new(
                Supervisor, PersistentKey, Key, InitialState);
        Table ->
            case ets:info(Table) of
                undefined ->
                    connection_limit_state_new(
                        Supervisor, PersistentKey, Key, InitialState);
                _ ->
                    [{state, State}] = ets:lookup(Table, state),
                    State
            end
    end.

connection_limit_supervisor() ->
    case erlang:get('$ancestors') of
        [Pid | _] when is_pid(Pid) -> Pid;
        _ -> erlang:error(connection_limit_supervisor_missing)
    end.

connection_limit_state_new(Supervisor, PersistentKey, Key, InitialState) ->
    Heir = connection_limit_state_heir_start(Supervisor, PersistentKey),
    Table = ets:new(beryl_connection_limit_state,
                    [set, public, {heir, Heir, Key}]),
    true = ets:insert(Table, {state, InitialState}),
    persistent_term:put(PersistentKey, Table),
    Heir ! {connection_limit_table, Table},
    InitialState.

connection_limit_state_heir_start(Supervisor, PersistentKey) ->
    spawn(fun() ->
        connection_limit_state_heir(Supervisor, PersistentKey)
    end).

connection_limit_state_heir(Supervisor, PersistentKey) ->
    Monitor = erlang:monitor(process, Supervisor),
    receive
        {connection_limit_table, Table} ->
            connection_limit_state_heir_wait(
                Supervisor, Monitor, PersistentKey, Table);
        {'ETS-TRANSFER', Table, _From, _HeirData} ->
            connection_limit_state_heir_wait(
                Supervisor, Monitor, PersistentKey, Table);
        {'DOWN', Monitor, process, Supervisor, _Reason} ->
            _ = persistent_term:erase(PersistentKey),
            ok
    end.

connection_limit_state_heir_wait(Supervisor, Monitor, PersistentKey, Table) ->
    receive
        {'ETS-TRANSFER', Table, _From, _HeirData} ->
            connection_limit_state_heir_wait(
                Supervisor, Monitor, PersistentKey, Table);
        {'DOWN', Monitor, process, Supervisor, _Reason} ->
            case persistent_term:get(PersistentKey, undefined) of
                Table -> persistent_term:erase(PersistentKey);
                _ -> ok
            end
    end.

connection_limit_state_put(Key, State) ->
    Supervisor = connection_limit_supervisor(),
    PersistentKey = {?MODULE, connection_limit_state, Supervisor, Key},
    Table = persistent_term:get(PersistentKey),
    true = ets:insert(Table, {state, State}),
    nil.

%% Check if a string starts with a prefix
string_starts_with(String, Prefix) ->
    PrefixLen = byte_size(Prefix),
    case String of
        <<Prefix:PrefixLen/binary, _/binary>> -> true;
        _ -> false
    end.

%% Stop a supervisor process cleanly.
%% Unlinks first so the calling process is not affected, then sends
%% a shutdown exit signal which the supervisor handles by terminating
%% all children before itself.
stop_supervisor(Pid) ->
    erlang:unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    erlang:exit(Pid, shutdown),
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> nil
    after
        5000 ->
            erlang:demonitor(MRef, [flush]),
            erlang:exit(Pid, kill),
            nil
    end.
