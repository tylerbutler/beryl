-module(beryl_test_process_ffi).
-export([
    mailbox_length/1,
    monitored_by_count/1,
    suspend_process/1,
    resume_process/1
]).

mailbox_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

monitored_by_count(Pid) ->
    case erlang:process_info(Pid, monitored_by) of
        {monitored_by, Monitors} -> length(Monitors);
        undefined -> 0
    end.

suspend_process(Pid) ->
    true = erlang:suspend_process(Pid),
    nil.

resume_process(Pid) ->
    erlang:resume_process(Pid),
    nil.
