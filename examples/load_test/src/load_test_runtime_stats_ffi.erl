-module(load_test_runtime_stats_ffi).
-export([snapshot/0]).

snapshot() ->
    try
        {ok, {snapshot,
              erlang:system_info(process_count),
              erlang:system_info(port_count),
              erlang:memory(total),
              erlang:statistics(run_queue),
              erlang:system_info(schedulers_online),
              unicode:characters_to_binary(erlang:system_info(otp_release))}}
    catch
        _:_ -> {error, nil}
    end.
