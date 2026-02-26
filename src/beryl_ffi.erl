-module(beryl_ffi).
-export([identity/1, monotonic_time_ms/0, stop_supervisor/1]).

%% Identity function for type erasure
identity(X) -> X.

%% Return Erlang monotonic time in milliseconds
monotonic_time_ms() -> erlang:monotonic_time(millisecond).

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
