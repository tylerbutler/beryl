-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, monotonic_time_ns/0,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         admission_token_new/0, admission_token_cancel/1,
         admission_token_pending/1, admission_token_claim/1, admission_token_owner/1,
         reservation_token_pending/1,
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
                io_lib:format("~p:~P", [Class, Reason, 10])),
            {error, string:slice(Formatted, 0, 512)}
    end.

%% Return Erlang monotonic time in milliseconds
monotonic_time_ms() -> erlang:monotonic_time(millisecond).

%% Return Erlang monotonic time in nanoseconds
monotonic_time_ns() -> erlang:monotonic_time(nanosecond).

admission_token_new() ->
    Token = atomics:new(1, [{signed, false}]),
    atomics:put(Token, 1, 0),
    {Token, self()}.

admission_token_cancel({Token, _Owner}) ->
    atomics:compare_exchange(Token, 1, 0, 2) =:= ok.

admission_token_owner({_Token, Owner}) -> Owner.

admission_token_pending({Token, Owner}) ->
    is_process_alive(Owner) andalso atomics:get(Token, 1) =:= 0.

%% Reservation ownership transfers independently of the token's creator.
reservation_token_pending({Token, _Owner}) ->
    atomics:get(Token, 1) =:= 0.

admission_token_claim({Token, Owner}) ->
    is_process_alive(Owner) andalso atomics:compare_exchange(Token, 1, 0, 1) =:= ok.

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
