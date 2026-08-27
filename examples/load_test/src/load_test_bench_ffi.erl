-module(load_test_bench_ffi).
-export([busy_wait/1]).

%% Burn CPU on the calling process for `Micros` microseconds, standing in
%% for an application callback with real cost (a DB round trip, a large
%% payload). Unlike `timer:sleep/1` it holds the scheduler, so it measures
%% callback cost the way a real callback would be paid.
busy_wait(Micros) when Micros =< 0 -> nil;
busy_wait(Micros) ->
    spin(erlang:monotonic_time(microsecond) + Micros).

spin(Deadline) ->
    case erlang:monotonic_time(microsecond) >= Deadline of
        true -> nil;
        false -> spin(Deadline)
    end.
