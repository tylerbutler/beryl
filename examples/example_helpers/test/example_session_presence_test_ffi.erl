-module(example_session_presence_test_ffi).
-export([mailbox_length/1, monitor_count/1, collected_memory/1, with_suspended/2]).

mailbox_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

monitor_count(Pid) ->
    case erlang:process_info(Pid, monitors) of
        {monitors, Monitors} -> length(Monitors);
        undefined -> erlang:error({monitor_count_process_dead, Pid})
    end.

collected_memory(Pid) ->
    case erlang:garbage_collect(Pid) of
        true ->
            case erlang:process_info(Pid, memory) of
                {memory, Bytes} -> Bytes;
                undefined -> erlang:error({collected_memory_process_dead, Pid})
            end;
        false ->
            erlang:error({collected_memory_process_dead, Pid})
    end.

with_suspended(Pid, Action) ->
    true = erlang:suspend_process(Pid),
    try Action()
    after erlang:resume_process(Pid)
    end.
