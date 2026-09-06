-module(beryl_runtime_telemetry_test_ffi).
-export([
    attach/0,
    detach/1,
    expect_connected/1,
    expect_join/2,
    expect_message/4,
    expect_disconnect/3,
    expect_broadcast/3,
    expect_none/1
]).

attach() ->
    HandlerId = {?MODULE, make_ref()},
    Self = self(),
    ok = telemetry:attach_many(
        HandlerId,
        [
            [beryl, socket, connected],
            [beryl, socket, disconnected],
            [beryl, channel, join, stop],
            [beryl, channel, message, stop],
            [beryl, broadcast, stop]
        ],
        fun(Event, Measurements, Metadata, _Config) ->
            Self ! {HandlerId, Event, Measurements, Metadata}
        end,
        nil
    ),
    HandlerId.

detach(HandlerId) ->
    ok = telemetry:detach(HandlerId),
    flush(HandlerId),
    nil.

expect_connected(HandlerId) ->
    receive
        {HandlerId, [beryl, socket, connected], #{count := 1}, Metadata}
            when map_size(Metadata) =:= 0 ->
            true
    after 500 ->
        false
    end.

expect_join(HandlerId, Outcome) ->
    ExpectedOutcome = expected_atom(Outcome),
    receive
        {
            HandlerId,
            [beryl, channel, join, stop],
            #{count := 1, duration := Duration},
            #{outcome := ExpectedOutcome}
        } when is_integer(Duration), Duration >= 0 ->
            true
    after 500 ->
        false
    end.

expect_message(HandlerId, Kind, Outcome, CallbackResult) ->
    ExpectedKind = expected_atom(Kind),
    ExpectedOutcome = expected_atom(Outcome),
    ExpectedCallbackResult = expected_atom(CallbackResult),
    receive
        {
            HandlerId,
            [beryl, channel, message, stop],
            #{count := 1, duration := Duration},
            #{
                kind := ExpectedKind,
                outcome := ExpectedOutcome,
                callback_result := ExpectedCallbackResult
            }
        } when is_integer(Duration), Duration >= 0 ->
            true
    after 500 ->
        false
    end.

expect_disconnect(HandlerId, Reason, JoinedTopics) ->
    ExpectedReason = expected_atom(Reason),
    receive
        {
            HandlerId,
            [beryl, socket, disconnected],
            #{
                count := 1,
                duration := Duration,
                joined_channels := JoinedTopics
            },
            #{reason := ExpectedReason}
        } when is_integer(Duration), Duration >= 0 ->
            true
    after 500 ->
        false
    end.

expect_broadcast(HandlerId, Origin, Recipients) ->
    ExpectedOrigin = expected_atom(Origin),
    receive
        {
            HandlerId,
            [beryl, broadcast, stop],
            #{
                count := 1,
                duration := Duration,
                recipients := Recipients
            },
            #{origin := ExpectedOrigin}
        } when is_integer(Duration), Duration >= 0 ->
            true
    after 500 ->
        false
    end.

expect_none(HandlerId) ->
    receive
        {HandlerId, _Event, _Measurements, _Metadata} ->
            false
    after 25 ->
        true
    end.

flush(HandlerId) ->
    receive
        {HandlerId, _Event, _Measurements, _Metadata} ->
            flush(HandlerId)
    after 0 ->
        ok
    end.

expected_atom(Value) ->
    binary_to_existing_atom(Value).
