-module(beryl_pubsub_test_ffi).
-export([is_scoped_wire_message/5]).

is_scoped_wire_message(Scope, Topic, Event, Payload, Timeout) ->
    receive
        {Scope, Topic, Event, Payload, system} -> true;
        {message, Topic, Event, Payload, system} -> false
    after Timeout ->
        false
    end.
