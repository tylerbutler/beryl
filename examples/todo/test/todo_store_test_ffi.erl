-module(todo_store_test_ffi).
-export([with_suspended/2]).

%% The caller must own an initially running OTP-compatible process and must
%% not suspend/resume it concurrently. The callback runs in the caller.
%% Failures remain test failures; cleanup is attempted even if the callback raises.
-spec with_suspended(pid(), fun(() -> Value)) -> Value.
with_suspended(Pid, Fun) ->
    ok = sys:suspend(Pid),
    try Fun()
    after
        ok = sys:resume(Pid)
    end.
