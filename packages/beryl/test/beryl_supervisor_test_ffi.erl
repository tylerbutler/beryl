-module(beryl_supervisor_test_ffi).
-export([get_subject_pid/1, crash_reason/0,
         gate_new/0, gate_wait/1, gate_release/1]).

%% Extract the process that will receive messages for a subject.
%% For named subjects, the name is registered with the process.
get_subject_pid(Subject) ->
    case Subject of
        %% Named subject: {named_subject, Name}
        {named_subject, Name} ->
            case erlang:whereis(Name) of
                undefined -> {error, nil};
                Pid -> {ok, Pid}
            end;
        %% Regular subject: {subject, OwnerPid, _Tag}
        {subject, Pid, _} ->
            {ok, Pid}
    end.

%% Return an atom that serves as an abnormal exit reason
crash_reason() ->
    test_crash.

gate_new() ->
    Gate = atomics:new(1, [{signed, false}]),
    atomics:put(Gate, 1, 0),
    Gate.

gate_wait(Gate) ->
    case atomics:get(Gate, 1) of
        1 -> nil;
        0 ->
            receive
            after 1 ->
                gate_wait(Gate)
            end
    end.

gate_release(Gate) ->
    atomics:put(Gate, 1, 1),
    nil.
