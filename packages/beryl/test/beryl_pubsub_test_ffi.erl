-module(beryl_pubsub_test_ffi).
-export([is_raw_wire_message/4]).

is_raw_wire_message(Topic, Event, Payload, Timeout) ->
    receive
        {message, Topic, Event, Payload, system} -> true;
        {beryl_pubsub_message, {message, Topic, Event, Payload, system}} ->
            false
    after Timeout ->
        false
    end.
