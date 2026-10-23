-module(load_test_bench_ffi).
-export([wait_elapsed/1]).

%% Busy-wait until `Micros` microseconds have elapsed. The loop uses CPU while
%% scheduled, but it is preemptible and suspension time advances the deadline.
%% It does not provide a fixed or calibrated amount of CPU work.
wait_elapsed(Micros) when Micros =< 0 -> nil;
wait_elapsed(Micros) ->
    spin(erlang:monotonic_time(microsecond) + Micros).

spin(Deadline) ->
    case erlang:monotonic_time(microsecond) >= Deadline of
        true -> nil;
        false -> spin(Deadline)
    end.
