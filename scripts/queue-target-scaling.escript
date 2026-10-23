#!/usr/bin/env escript
%% Run from the repository root:
%% ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1' escript scripts/queue-target-scaling.escript
%% Optional argument: directory containing an earlier beryl_work_queue_ffi.beam.
%% Prepare and run the original baseline from the repository root:
%% mkdir -p build/queue-target-baseline
%% git archive 27a91eeaf93d3e6553c30558eac598abfd6f99dd packages/beryl/src/beryl_work_queue_ffi.erl | tar -x -C build/queue-target-baseline
%% erlc -o build/queue-target-baseline build/queue-target-baseline/packages/beryl/src/beryl_work_queue_ffi.erl
%% ERL_FLAGS='+S 2:2 +SDcpu 1 +SDio 1' escript scripts/queue-target-scaling.escript build/queue-target-baseline
-mode(compile).

main(Arguments) ->
    case Arguments of
        [] ->
            {ok, Module, Binary} = compile:file(
                "packages/beryl/src/beryl_work_queue_ffi.erl", [binary, warnings_as_errors]),
            {module, Module} = code:load_binary(Module, "current", Binary);
        [Directory] ->
            true = code:add_patha(Directory)
    end,
    io:format("~sSchedulers: ~p; iterations=1000; runs=5; telemetry=false~n",
        [erlang:system_info(system_version), erlang:system_info(schedulers_online)]),
    lists:foreach(fun(Targets) ->
        Samples = [sample(Targets, 1000) || _ <- lists:seq(1, 5)],
        io:format("targets=~p median_us/cycle=~.3f median_reductions/cycle=~.3f samples=~p~n",
            [Targets, median([Time || {Time, _} <- Samples]),
             median([Reductions || {_, Reductions} <- Samples]), Samples])
    end, [1, 100, 1000]).

sample(Targets, Iterations) ->
    Queue = beryl_work_queue_ffi:new(8, 4096, router_queue, false, fun() -> nil end),
    TargetQueues = [
        {integer_to_binary(Key),
         beryl_work_queue_ffi:new(8, 4096, socket_queue, false, fun() -> nil end)}
        || Key <- lists:seq(1, Targets)
    ],
    %% Setup is outside the measurement. No registry inspection in the loop.
    try
        lists:foreach(fun({Key, Target}) ->
            nil = beryl_work_queue_ffi:register_target(Queue, Key, Target)
        end, TargetQueues),
        cycle(Queue, 100),
        erlang:garbage_collect(),
        {reductions, Before} = process_info(self(), reductions),
        Start = erlang:monotonic_time(),
        cycle(Queue, Iterations),
        Elapsed = erlang:convert_time_unit(erlang:monotonic_time() - Start, native, nanosecond),
        {reductions, After} = process_info(self(), reductions),
        {Elapsed / (1000 * Iterations), (After - Before) / Iterations}
    after
        true = ets:delete(element(1, Queue)),
        lists:foreach(fun({_, Target}) ->
            true = ets:delete(element(1, Target))
        end, TargetQueues)
    end.

cycle(_, 0) -> ok;
cycle(Queue, Count) ->
    {ok, Id} = beryl_work_queue_ffi:publish(Queue, <<"payload">>, 7),
    {ok, {Id, <<"payload">>}} = beryl_work_queue_ffi:take(Queue),
    nil = beryl_work_queue_ffi:release(Queue, Id),
    {error, empty} = beryl_work_queue_ffi:take(Queue),
    cycle(Queue, Count - 1).

median(Values) -> lists:nth(3, lists:sort(Values)).
