-module(beryl_telemetry_test_ffi).
-export([attach_socket_connected/0, detach/1, received_socket_connected/0]).

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
