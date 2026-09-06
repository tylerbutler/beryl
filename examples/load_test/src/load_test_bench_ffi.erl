-module(load_test_bench_ffi).
-export([busy_wait/1]).

%% Use CPU on the calling process for `Micros` microseconds. This operation
%% represents application callback work, such as a database request or a
%% large payload. Unlike `timer:sleep/1`, it holds the scheduler.
busy_wait(Micros) when Micros =< 0 -> nil;
busy_wait(Micros) ->
    spin(erlang:monotonic_time(microsecond) + Micros).

spin(Deadline) ->
    case erlang:monotonic_time(microsecond) >= Deadline of
        true -> nil;
        false -> spin(Deadline)
    end.
