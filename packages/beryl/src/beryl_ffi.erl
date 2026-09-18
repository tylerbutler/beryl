-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, monotonic_time_ns/0,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         admission_token_new/0, admission_token_cancel/1,
         admission_token_pending/1, admission_token_claim/1, admission_token_owner/1,
         reservation_token_pending/1,
         connection_limit_call/3, connection_limit_send/2,
         connection_limit_checkpoint_supervisor/0,
         connection_limit_checkpoint_registry_key/2,
         connection_limit_checkpoint_registry_get/1,
         connection_limit_checkpoint_registry_put/2,
         connection_limit_checkpoint_registry_compare_erase/2]).

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
