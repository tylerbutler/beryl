-module(beryl_telemetry_test_ffi).
-export([attach_socket_connected/0, detach/1, received_socket_connected/0,
         attach_queue/0, assert_queue_event/4, assert_no_queue_event/0,
         attach_transport/0, receive_upgrade/1, receive_frame/1,
         no_transport_events/1]).

attach_transport() ->
    HandlerId = {beryl_transport_test, make_ref()},
    Owner = self(),
    ok = telemetry:attach_many(HandlerId,
        [[beryl, transport, upgrade, stop], [beryl, transport, frame, stop]],
        fun(Event, Measurements, Metadata, _) ->
            case self() =:= Owner of
                true ->
                    Owner ! {beryl_transport_test, HandlerId,
                             Event, Measurements, Metadata};
                false -> ok
            end
        end, nil),
    HandlerId.

%% Consume only this capture's messages. Unexpected shapes fail as typed errors
%% rather than being skipped by a more restrictive selective receive.
receive_upgrade(HandlerId) ->
    receive
        {beryl_transport_test, HandlerId, [beryl, transport, upgrade, stop],
         #{count := Count, duration := Duration} = Measurements,
         #{transport := Transport, outcome := Outcome} = Metadata}
            when map_size(Measurements) =:= 2, map_size(Metadata) =:= 2,
                 is_integer(Count), is_integer(Duration), is_atom(Outcome),
                 (Transport =:= custom orelse Transport =:= mist orelse
                  Transport =:= ewe) ->
            {ok, {Count, Duration, atom_to_binary(Transport, utf8),
                  atom_to_binary(Outcome, utf8)}};
        {beryl_transport_test, HandlerId, _, _, _} -> {error, nil}
    after 1000 -> {error, nil}
    end.

receive_frame(HandlerId) ->
    receive
        {beryl_transport_test, HandlerId, [beryl, transport, frame, stop],
         #{count := Count, duration := Duration, bytes := Bytes} = Measurements,
         #{transport := Transport, frame_type := Kind,
           outcome := Outcome} = Metadata}
            when map_size(Measurements) =:= 3, map_size(Metadata) =:= 3,
                 is_integer(Count), is_integer(Duration), is_integer(Bytes),
                 is_atom(Kind), is_atom(Outcome),
                 (Transport =:= custom orelse Transport =:= mist orelse
                  Transport =:= ewe) ->
            {ok, {Count, Duration, Bytes, atom_to_binary(Transport, utf8),
                  atom_to_binary(Kind, utf8), atom_to_binary(Outcome, utf8)}};
        {beryl_transport_test, HandlerId, _, _, _} -> {error, nil}
    after 1000 -> {error, nil}
    end.

no_transport_events(HandlerId) ->
    receive
        {beryl_transport_test, HandlerId, _, _, _} -> false
    after 0 -> true
    end.

attach_queue() ->
    HandlerId = {beryl_queue_test, make_ref()},
    Owner = self(),
    ok = telemetry:attach(HandlerId, [beryl, queue, occupancy],
        fun(Event, Measurements, Metadata, _) ->
            case self() =:= Owner of
                true -> Owner ! {beryl_queue_test, Event, Measurements, Metadata};
                false -> ok
            end
        end, nil),
    HandlerId.

assert_queue_event(Items, Rejected, Cancelled, Outcome) ->
    receive
        {beryl_queue_test, [beryl, queue, occupancy],
         #{items := Items, bytes := Bytes, max_items := 1, max_bytes := 8,
           high_items := 1, high_bytes := 8, rejected := Rejected,
           cancelled := Cancelled, oldest_age_ms := Age} = Measurements,
         #{boundary := worker_queue, outcome := Outcome} = Metadata}
            when map_size(Measurements) =:= 9, map_size(Metadata) =:= 2,
                 Bytes =:= Items * 8, Age >= 0 -> nil
    after 1000 -> error(missing_queue_event)
    end.

assert_no_queue_event() ->
    receive
        {beryl_queue_test, _, _, _} -> error(unexpected_queue_event)
    after 0 -> nil
    end.

attach_socket_connected() ->
    HandlerId = {beryl_telemetry_test, make_ref()},
    Self = self(),
    ok = telemetry:attach(
        HandlerId,
        [beryl, socket, connected],
        fun(Event, Measurements, Metadata, _Config) ->
            Self ! {beryl_telemetry_test, Event, Measurements, Metadata}
        end,
        nil
    ),
    HandlerId.

detach(HandlerId) ->
    ok = telemetry:detach(HandlerId),
    nil.

received_socket_connected() ->
    receive
        {
            beryl_telemetry_test,
            [beryl, socket, connected],
            #{count := 1},
            Metadata
        } when map_size(Metadata) =:= 0 ->
            true
    after
        0 ->
            false
    end.
