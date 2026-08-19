-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, monotonic_time_ns/0,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         admission_token_new/0, admission_token_cancel/1,
         admission_token_pending/1, admission_token_claim/1]).

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
    Token.

admission_token_cancel(Token) ->
    atomics:compare_exchange(Token, 1, 0, 2) =:= ok.

admission_token_pending(Token) ->
    atomics:get(Token, 1) =:= 0.

admission_token_claim(Token) ->
    atomics:compare_exchange(Token, 1, 0, 1) =:= ok.

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
