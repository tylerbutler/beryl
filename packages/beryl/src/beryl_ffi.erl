-module(beryl_ffi).
-export([identity/1,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         connection_limit_checkpoint_supervisor/0,
         connection_limit_checkpoint_registry_key/2,
         connection_limit_checkpoint_registry_get/1,
         connection_limit_checkpoint_registry_put/2,
         connection_limit_checkpoint_registry_compare_erase/2,
         pin_subject/1]).

%% Used only after a selector validates the frozen raw PubSub record shape.
identity(X) -> X.

%% Resolve once and retain the existing subject tag. Sending to this captured
%% pid after an exit is safe and cannot reach a replacement registered name.
pin_subject({named_subject, Name}) when is_atom(Name) ->
    case erlang:whereis(Name) of
        undefined -> {error, nil};
        Pid -> {ok, {{subject, Pid, Name}, Pid}}
    end;
pin_subject({subject, Pid, _Tag} = Subject) when is_pid(Pid) ->
    {ok, {Subject, Pid}}.

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

connection_limit_checkpoint_supervisor() ->
    case erlang:get('$ancestors') of
        [Pid | _] when is_pid(Pid) -> Pid;
        _ -> erlang:error(connection_limit_supervisor_missing)
    end.

connection_limit_checkpoint_registry_key(Supervisor, Key) ->
    {?MODULE, connection_limit_state, Supervisor, Key}.

connection_limit_checkpoint_registry_get(PersistentKey) ->
    case persistent_term:get(PersistentKey, undefined) of
        undefined -> none;
        Table -> {some, Table}
    end.

connection_limit_checkpoint_registry_put(PersistentKey, Table) ->
    persistent_term:put(PersistentKey, Table),
    nil.

connection_limit_checkpoint_registry_compare_erase(PersistentKey, Table) ->
    case persistent_term:get(PersistentKey, undefined) of
        Table -> persistent_term:erase(PersistentKey);
        _ -> ok
    end,
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
