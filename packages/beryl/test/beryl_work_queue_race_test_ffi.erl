-module(beryl_work_queue_race_test_ffi).
-export([registry_races/0, parse_transform/2, before_cas/0]).

-define(QUEUE, beryl_work_queue_race_fixture).

%% Compile the actual queue source into an isolated test module, in memory.
%% Only the module name and a one-shot barrier before its CAS are changed.
%% This leaves the released module and its hot path free of test hooks.
parse_transform(Forms, _) ->
    [case Form of
        {attribute, Line, module, beryl_work_queue_ffi} ->
            {attribute, Line, module, ?QUEUE};
        {function, Line, replace, 2, [{clause, At, Args, Guards, Body}]} ->
            Hook = {call, At, {remote, At,
                {atom, At, ?MODULE}, {atom, At, before_cas}}, []},
            {function, Line, replace, 2, [{clause, At, Args, Guards, [Hook | Body]}]};
        _ -> Form
    end || Form <- Forms].

before_cas() ->
    case erase(queue_cas_barrier) of
        undefined -> ok;
        {Parent, Tag, skip_first} ->
            put(queue_cas_barrier, {Parent, Tag}),
            ok;
        {Parent, Tag} ->
            Parent ! {Tag, before_cas},
            receive {Tag, continue} -> ok
            after 5000 -> error(cas_barrier_timeout)
            end
    end.

registry_races() ->
    {ok, ?QUEUE, Binary} = compile:file("src/beryl_work_queue_ffi.erl",
        [binary, warnings_as_errors, {parse_transform, ?MODULE}]),
    {module, ?QUEUE} = code:load_binary(?QUEUE, "queue-race-fixture", Binary),
    try
        admission_before_close(),
        close_before_admission(),
        lists:foreach(fun stale_close/1, [remove, replace, complete]),
        bounded_controls(),
        yielded_registry_changes(),
        odd_epoch_allows_data(),
        telemetry_only_at_even_epoch(),
        nil
    after
        true = code:delete(?QUEUE),
        _ = code:purge(?QUEUE)
    end.

new_queue() ->
    ?QUEUE:new(1, 8, router_queue, false, fun() -> nil end).

fixture() ->
    Queue = new_queue(),
    Target = new_queue(),
    nil = ?QUEUE:register_target(Queue, <<"socket">>, Target),
    {Queue, Target}.

%% Close has read an open row and prepared its CAS. Data wins the CAS first.
%% Retrying the close must put its control AFTER that data.
admission_before_close() ->
    {Queue, Target} = fixture(),
    {Publisher, Monitor, Tag} = paused(fun() -> ?QUEUE:close_target(Queue, <<"socket">>) end),
    try
        {ok, Id} = ?QUEUE:publish(Queue, <<"data">>, 8),
        resume(Publisher, Monitor, Tag, nil),
        {ok, {Id, <<"data">>}} = ?QUEUE:take(Queue),
        true = ?QUEUE:is_open(Target),
        nil = ?QUEUE:release(Queue, Id),
        {error, empty} = ?QUEUE:take(Queue),
        false = ?QUEUE:is_open(Target),
        assert_empty_controls(Queue)
    after cleanup(Publisher, Monitor, [Queue, Target]) end.

%% Data has prepared its CAS. Close wins first. The data retry must append
%% AFTER the control, so take closes the target before returning that data.
close_before_admission() ->
    {Queue, Target} = fixture(),
    {Publisher, Monitor, Tag} = paused(fun() -> ?QUEUE:publish(Queue, <<"data">>, 8) end),
    try
        nil = ?QUEUE:close_target(Queue, <<"socket">>),
        {ok, Id} = resume(Publisher, Monitor, Tag, any),
        {ok, {Id, <<"data">>}} = ?QUEUE:take(Queue),
        false = ?QUEUE:is_open(Target),
        nil = ?QUEUE:release(Queue, Id),
        assert_empty_controls(Queue)
    after cleanup(Publisher, Monitor, [Queue, Target]) end.

%% The publisher is paused AFTER reading the open row and preparing the CAS.
%% Removal, reincarnation, or completing a competing close invalidates it.
stale_close(Transition) ->
    {Queue, Target} = fixture(),
    Replacement = new_queue(),
    {Publisher, Monitor, Tag} = paused(fun() -> ?QUEUE:close_target(Queue, <<"socket">>) end),
    try
        case Transition of
            remove -> nil = ?QUEUE:remove_target(Queue, <<"socket">>);
            replace -> nil = ?QUEUE:register_target(Queue, <<"socket">>, Replacement);
            complete ->
                nil = ?QUEUE:close_target(Queue, <<"socket">>),
                {error, empty} = ?QUEUE:take(Queue)
        end,
        resume(Publisher, Monitor, Tag, nil),
        assert_empty_controls(Queue),
        {error, empty} = ?QUEUE:take(Queue),
        true = ?QUEUE:is_open(Replacement),
        case Transition of
            complete -> false = ?QUEUE:is_open(Target);
            _ -> true = ?QUEUE:is_open(Target)
        end,
        %% A new incarnation must still be independently closeable.
        nil = ?QUEUE:register_target(Queue, <<"socket">>, Replacement),
        nil = ?QUEUE:close_target(Queue, <<"socket">>),
        {error, empty} = ?QUEUE:take(Queue),
        false = ?QUEUE:is_open(Replacement),
        assert_empty_controls(Queue)
    after cleanup(Publisher, Monitor, [Queue, Target, Replacement]) end.

%% A turn completes at most 16 controls, preserving FIFO data and the
%% remaining controls' deduplication entries across yields.
bounded_controls() ->
    Queue = new_queue(),
    Targets = [{N, new_queue()} || N <- lists:seq(1, 33)],
    try
        lists:foreach(fun({Key, Target}) ->
            nil = ?QUEUE:register_target(Queue, Key, Target),
            nil = ?QUEUE:close_target(Queue, Key)
        end, Targets),
        {ok, Id} = ?QUEUE:publish(Queue, <<"data">>, 8),
        {error, yielded} = ?QUEUE:take(Queue),
        assert_closed_prefix(Targets, 16),
        assert_pending_controls(Queue, 17),
        lists:foreach(fun({Key, _}) ->
            nil = ?QUEUE:close_target(Queue, Key)
        end, Targets),
        assert_pending_controls(Queue, 17),
        {error, yielded} = ?QUEUE:take(Queue),
        assert_closed_prefix(Targets, 32),
        assert_pending_controls(Queue, 1),
        {ok, {Id, <<"data">>}} = ?QUEUE:take(Queue),
        assert_closed_prefix(Targets, 33),
        nil = ?QUEUE:release(Queue, Id),
        {error, empty} = ?QUEUE:take(Queue),
        assert_empty_controls(Queue)
    after
        lists:foreach(fun(Q) -> true = ets:delete(element(1, Q)) end,
                      [Queue | [Target || {_, Target} <- Targets]])
    end.

%% Pending controls remain cancellable by removal/reincarnation after a
%% yield. Exactly 16 completed controls followed by empty is Empty, not Yielded.
yielded_registry_changes() ->
    Queue = new_queue(),
    Replacement = new_queue(),
    Targets = [{N, new_queue()} || N <- lists:seq(1, 18)],
    try
        lists:foreach(fun({Key, Target}) ->
            nil = ?QUEUE:register_target(Queue, Key, Target),
            nil = ?QUEUE:close_target(Queue, Key)
        end, Targets),
        {error, yielded} = ?QUEUE:take(Queue),
        assert_pending_controls(Queue, 2),
        nil = ?QUEUE:register_target(Queue, 17, Replacement),
        nil = ?QUEUE:remove_target(Queue, 18),
        {error, empty} = ?QUEUE:take(Queue),
        assert_closed_prefix(Targets, 16),
        true = ?QUEUE:is_open(Replacement),
        assert_empty_controls(Queue),
        nil = ?QUEUE:close_target(Queue, 17),
        {error, empty} = ?QUEUE:take(Queue),
        false = ?QUEUE:is_open(Replacement),
        assert_empty_controls(Queue),
        lists:foreach(fun({Key, Target}) ->
            nil = ?QUEUE:register_target(Queue, Key, Target),
            nil = ?QUEUE:close_target(Queue, Key)
        end, lists:sublist(Targets, 16)),
        {error, empty} = ?QUEUE:take(Queue),
        assert_empty_controls(Queue)
    after
        lists:foreach(fun(Q) -> true = ets:delete(element(1, Q)) end,
                      [Queue, Replacement | [Target || {_, Target} <- Targets]])
    end.

assert_closed_prefix(Targets, Closed) ->
    lists:foreach(fun({Key, Target}) ->
        ExpectedOpen = Key > Closed,
        ExpectedOpen = ?QUEUE:is_open(Target)
    end, Targets).

assert_pending_controls(Queue, Count) ->
    [{state, State}] = ets:lookup(element(1, Queue), state),
    Count = map_size(maps:get(pending_closes, State)),
    Count = length([Control || Control = {target_close, _, _, _} <-
                                  queue:to_list(maps:get(pending, State))]),
    0 = maps:get(registry_epoch, State) rem 2,
    ok.

%% Pause the owner between the odd-epoch CAS and the even-epoch cleanup.
%% The data publisher must not wait for the registry transition to finish.
odd_epoch_allows_data() ->
    Parent = self(),
    Tag = make_ref(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        Queue = new_queue(),
        Target = new_queue(),
        nil = ?QUEUE:register_target(Queue, <<"socket">>, Target),
        Parent ! {Tag, queue, Queue},
        %% register/remove each do two CAS operations. The second barrier
        %% observes an odd epoch and the changed registry row.
        put(queue_cas_barrier, {Parent, Tag, skip_first}),
        nil = ?QUEUE:remove_target(Queue, <<"socket">>),
        Parent ! {Tag, removed},
        receive {Tag, stop} -> ok end
    end),
    try
        Queue = receive {Tag, queue, Value} -> Value
                after 5000 -> error(owner_setup_timeout) end,
        receive {Tag, before_cas} -> ok after 5000 -> error(owner_barrier_timeout) end,
        [{state, #{registry_epoch := Epoch}}] = ets:lookup(element(1, Queue), state),
        1 = Epoch rem 2,
        {ok, Id} = ?QUEUE:publish(Queue, <<"data">>, 8),
        nil = ?QUEUE:release(Queue, Id),
        Owner ! {Tag, continue},
        receive {Tag, removed} -> ok after 5000 -> error(remove_timeout) end,
        assert_empty_controls(Queue)
    after
        cleanup(Owner, Monitor, [])
    end.

paused(Action) ->
    Parent = self(),
    Tag = make_ref(),
    {Publisher, Monitor} = spawn_monitor(fun() ->
        put(queue_cas_barrier, {Parent, Tag}),
        Result = Action(),
        Parent ! {Tag, result, Result}
    end),
    receive {Tag, before_cas} -> {Publisher, Monitor, Tag}
    after 5000 ->
        cleanup(Publisher, Monitor, []),
        error(publisher_barrier_timeout)
    end.

resume(Publisher, Monitor, Tag, Expected) ->
    Publisher ! {Tag, continue},
    Result = receive {Tag, result, Value} -> Value
             after 5000 -> error(publisher_result_timeout) end,
    case Expected of any -> ok; Result -> ok end,
    receive {'DOWN', Monitor, process, Publisher, normal} -> ok
    after 5000 -> error(publisher_exit_timeout)
    end,
    Result.

assert_empty_controls(Queue) ->
    [{state, State}] = ets:lookup(element(1, Queue), state),
    0 = map_size(maps:get(pending_closes, State)),
    false = maps:is_key(targets, State),
    0 = maps:get(registry_epoch, State) rem 2,
    [] = [Control || Control = {target_close, _, _, _} <-
                        queue:to_list(maps:get(pending, State))],
    ok.

telemetry_only_at_even_epoch() ->
    Parent = self(),
    Tag = make_ref(),
    Queue = beryl_work_queue_ffi:new(1, 8, router_queue, true, fun() -> nil end),
    Target = beryl_work_queue_ffi:new(1, 8, socket_queue, false, fun() -> nil end),
    Table = element(1, Queue),
    ok = telemetry:attach(Tag, [beryl, queue, occupancy],
        fun(_, _, _, _) ->
            case self() =:= Parent of
                true ->
                    [{state, #{registry_epoch := Epoch}}] = ets:lookup(Table, state),
                    Parent ! {Tag, telemetry_epoch, Epoch};
                false -> ok
            end
        end, nil),
    try
        nil = beryl_work_queue_ffi:register_target(Queue, <<"socket">>, Target),
        nil = beryl_work_queue_ffi:close_target(Queue, <<"socket">>),
        {error, empty} = beryl_work_queue_ffi:take(Queue),
        nil = beryl_work_queue_ffi:remove_target(Queue, <<"socket">>),
        telemetry_epochs(Tag, 5)
    after
        ok = telemetry:detach(Tag),
        true = ets:delete(Table),
        true = ets:delete(element(1, Target))
    end.

telemetry_epochs(Tag, Remaining) ->
    receive
        {Tag, telemetry_epoch, Epoch} when Remaining > 0, Epoch rem 2 =:= 0 ->
            telemetry_epochs(Tag, Remaining - 1);
        {Tag, telemetry_epoch, Epoch} -> error({unexpected_telemetry_epoch, Epoch})
    after 0 ->
        0 = Remaining,
        ok
    end.

cleanup(Process, Monitor, Queues) ->
    CleanupMonitor = erlang:monitor(process, Process),
    exit(Process, kill),
    receive {'DOWN', CleanupMonitor, process, Process, _} -> ok
    after 5000 -> error(cleanup_exit_timeout)
    end,
    erlang:demonitor(Monitor, [flush]),
    lists:foreach(fun(Queue) -> true = ets:delete(element(1, Queue)) end, Queues).
