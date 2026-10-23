-module(beryl_runtime_telemetry_test_ffi).
-export([
    attach/0,
    detach/1,
    with_capture/1,
    with_race_runtime/5,
    with_actor_monitor/2,
    catch_injected_assertion/1,
    cleanup_baseline/1,
    expect_connected/1,
    expect_join/2,
    expect_message/4,
    expect_disconnect/3,
    expect_disconnect_after/4,
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

%% Capture outlives the runtime fixture, so no fixture producer can send after
%% detach's final handler-specific drain.
with_capture(Action) ->
    HandlerId = attach(),
    try Action(HandlerId)
    after detach(HandlerId)
    end.

%% Own the root supervisor as well as the runtime: start_app intentionally
%% discards that supervisor, which is unsuitable for a same-process failure test.
with_race_runtime(Supervisor, NotifyClosed, Stop, Drain, Action) ->
    Gate = beryl_supervisor_test_ffi:gate_new(),
    Release = fun() -> beryl_supervisor_test_ffi:gate_release(Gate) end,
    Close = fun() ->
        NotifyClosed(),
        beryl_supervisor_test_ffi:gate_wait(Gate)
    end,
    try Action(Close, Release)
    after
        Release(),
        try Stop()
        after
            try stop_supervisor(Supervisor)
            after Drain()
            end
        end
    end.

stop_supervisor(Supervisor) ->
    Monitor = erlang:monitor(process, Supervisor),
    unlink(Supervisor),
    try
        ok = gen_server:stop(Supervisor, normal, 10000),
        receive
            {'DOWN', Monitor, process, Supervisor, _Reason} -> ok
        after 1000 ->
            error(race_supervisor_did_not_exit)
        end
    after erlang:demonitor(Monitor, [flush])
    end.

with_actor_monitor(Actor, Action) ->
    Monitor = erlang:monitor(process, Actor),
    try Action(Monitor)
    after erlang:demonitor(Monitor, [flush])
    end.

%% Catch only the deliberate should.equal failure, not scenario/cleanup bugs.
catch_injected_assertion(Action) ->
    try Action() of
        nil -> false
    catch
        error:#{gleam_error := panic, module := <<"gleeunit/should">>,
                function := <<"equal">>, message := Message} ->
            case binary:match(Message, <<"injected race assertion">>) of
                nomatch -> error({unexpected_assertion, Message});
                _ -> true
            end
    end.

cleanup_baseline(Action) ->
    Before = baseline(),
    nil = Action(),
    case baseline() of
        Before -> true;
        After -> error({race_cleanup_changed_baseline, Before, After})
    end.

baseline() ->
    {monitors, Monitors} = process_info(self(), monitors),
    {links, Links} = process_info(self(), links),
    {messages, Messages} = process_info(self(), messages),
    Handlers = lists:usort([Id || #{id := Id} <- telemetry:list_handlers([])]),
    {lists:sort(Monitors), lists:sort(Links), Messages, Handlers}.

expect_connected(HandlerId) ->
    receive
        {HandlerId, [beryl, socket, connected], #{count := 1} = Measurements, Metadata}
            when map_size(Measurements) =:= 1, map_size(Metadata) =:= 0 ->
            true;
        {HandlerId, [beryl, socket, disconnected], _Measurements, _Metadata} ->
            false
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
    expect_disconnect_after(HandlerId, Reason, JoinedTopics, 1).

expect_disconnect_after(HandlerId, Reason, JoinedTopics, MinimumDuration) ->
    ExpectedReason = expected_atom(Reason),
    receive
        {
            HandlerId,
            [beryl, socket, disconnected],
            #{
                count := 1,
                duration := Duration,
                joined_channels := JoinedTopics
            } = Measurements,
            #{reason := ExpectedReason} = Metadata
        } when
            is_integer(Duration),
            Duration > 0,
            Duration >= MinimumDuration,
            map_size(Measurements) =:= 3,
            map_size(Metadata) =:= 1
        ->
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
