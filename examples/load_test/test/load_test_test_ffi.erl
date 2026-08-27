-module(load_test_test_ffi).
-export([run_after/2]).

run_after(Run, Cleanup) ->
    try Run()
    after Cleanup()
    end.
