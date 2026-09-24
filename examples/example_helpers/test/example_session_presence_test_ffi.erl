-module(example_session_presence_test_ffi).
-export([mailbox_length/1, with_suspended/2]).

mailbox_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

with_suspended(Pid, Action) ->
    true = erlang:suspend_process(Pid),
    try Action()
    after erlang:resume_process(Pid)
    end.
