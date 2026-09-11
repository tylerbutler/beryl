-module(load_test_test_ffi).
-export([elapsed_wait_advances_while_suspended/0, run_after/2]).

run_after(Run, Cleanup) ->
    try Run()
    after Cleanup()
    end.

elapsed_wait_advances_while_suspended() ->
    Parent = self(),
    Worker = spawn(fun() ->
        receive
            start ->
                load_test_bench_ffi:wait_elapsed(1000000),
                Parent ! {elapsed_wait_done, self()}
        end
    end),
    try
        {reductions, InitialReductions} = process_info(Worker, reductions),
        Worker ! start,
        case wait_for_reductions(Worker, InitialReductions + 1000, 500) of
            false -> false;
            true ->
                true = erlang:suspend_process(Worker),
                timer:sleep(1100),
                true = erlang:resume_process(Worker),
                receive
                    {elapsed_wait_done, Worker} -> true
                after 500 ->
                    false
                end
        end
    after
        catch erlang:resume_process(Worker),
        exit(Worker, kill)
    end.

wait_for_reductions(_Worker, _Minimum, 0) ->
    false;
wait_for_reductions(Worker, Minimum, Attempts) ->
    case process_info(Worker, reductions) of
        {reductions, Reductions} when Reductions >= Minimum -> true;
        undefined -> false;
        _ ->
            timer:sleep(1),
            wait_for_reductions(Worker, Minimum, Attempts - 1)
    end.
