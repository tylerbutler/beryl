-module(beryl_test_process_ffi).
-export([mailbox_length/1]).

mailbox_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.
