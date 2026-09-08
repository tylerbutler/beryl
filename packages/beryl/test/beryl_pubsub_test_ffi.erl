-module(beryl_pubsub_test_ffi).
-export([is_scoped_wire_message/5, drain_messages/5]).

drain_messages(Scope, Topic, Event, Payload, From) ->
    drain_messages(Scope, Topic, Event, Payload, From, 0).

drain_messages(Scope, Topic, Event, Payload, From, Count) ->
    receive
        {Scope, Topic, Event, Payload, From} ->
            drain_messages(Scope, Topic, Event, Payload, From, Count + 1)
    after 0 ->
        Count
    end.

is_scoped_wire_message(Scope, Topic, Event, Payload, Timeout) ->
    receive
        {Scope, Topic, Event, Payload, system} -> true;
        {message, Topic, Event, Payload, system} -> false
    after Timeout ->
        false
    end.
