-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, monotonic_time_ns/0, rescue/1]).

%% Identity coercion for pg message recovery (see beryl/pubsub).
identity(X) -> X.

%% Run a callback, converting any crash (error/exit/throw) into an
%% {error, Description} result so a crashing app callback cannot take
%% down the shared runtime actor. The description is depth-limited and
%% truncated so client-triggered crashes cannot bloat log metadata.
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
