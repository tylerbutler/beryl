-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, stop_supervisor/1,
         get_cached_logger/1, set_cached_logger/2]).

%% Identity function for type erasure
identity(X) -> X.

%% Return Erlang monotonic time in milliseconds
monotonic_time_ms() -> erlang:monotonic_time(millisecond).

%% Cached logger lookup via persistent_term (zero-alloc hot path).
get_cached_logger(Name) ->
    case persistent_term:get({beryl_logger, Name}, undefined) of
        undefined -> {error, nil};
        Value -> {ok, Value}
    end.

set_cached_logger(Name, Logger) ->
    persistent_term:put({beryl_logger, Name}, Logger),
    nil.

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
