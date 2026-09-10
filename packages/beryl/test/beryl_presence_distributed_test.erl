-module(beryl_presence_distributed_test).
-include_lib("eunit/include/eunit.hrl").
-export([start_replica/3, view/1, sync_round/1, kill_replica/1,
         begin_outage/1, end_outage/1, take_diffs/1, diff_history/1,
         retained/1, replica/1]).

-define(TOPIC, <<"room:distributed">>).
-define(SYNC_TOPIC, <<"beryl:presence:sync">>).
-define(SCOPE, <<"beryl_presence_distributed_test">>).

late_joiner_gets_quiet_snapshot_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            {ok, _} = track(A, Source, <<"before-join">>),
            await_round(A, Source),
            await_members(B, 1),
            %% No periodic timer on the newcomer: this must use its initial
            %% exchange, not a new application mutation or its next tick.
            Late = start(B, <<"late">>, 0),
            await_view(B, Late, [<<"before-join">>])
        end)
    end}.

quiet_partition_repair_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, OldRef} = track(A, Source, <<"before-partition">>),
            await_view(B, Receiver, [<<"before-partition">>]),
            disconnect(A, B),
            {ok, nil} = presence_call(A, untrack, [handle(Source), OldRef]),
            {ok, _} = track(A, Source, <<"during-partition">>),
            await_round(A, Source),
            ?assertEqual([], call(A, erlang, nodes, [])),
            ?assertEqual([], call(B, erlang, nodes, [])),
            connect(A, B),
            await_members(A, 2),
            await_members(B, 2),
            await_view(A, Source, [<<"during-partition">>]),
            await_view(B, Receiver, [<<"during-partition">>])
        end)
    end}.

quiet_pg_recovery_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, OldRef} = track(A, Source, <<"before-outage">>),
            await_view(B, Receiver, [<<"before-outage">>]),
            Outage = call(A, ?MODULE, begin_outage, [?SCOPE]),
            try
                await_members(B, 1),
                await_round(B, Receiver),
                {ok, nil} = presence_call(A, untrack, [handle(Source), OldRef]),
                {ok, _} = track(A, Source, <<"during-outage">>),
                await_round(A, Source),
                #{entries := BeforeRecovery} = call(B, ?MODULE, view, [Receiver]),
                ?assertNot(lists:member(
                    {<<"during-outage">>, <<"during-outage">>}, BeforeRecovery))
            after
                nil = call(A, ?MODULE, end_outage, [Outage])
            end,
            await_members(A, 2),
            await_members(B, 2),
            await_view(B, Receiver, [<<"during-outage">>])
        end)
    end}.

empty_restart_repairs_without_track_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, _} = track(A, Source, <<"source-entry">>),
            {ok, _} = track(B, Receiver, <<"receiver-entry">>),
            await_view(A, Source, [<<"receiver-entry">>, <<"source-entry">>]),
            nil = call(A, ?MODULE, kill_replica, [Source]),
            Restarted = start(A, <<"source">>, 30),
            await_view(A, Restarted, [<<"receiver-entry">>]),
            await_view(B, Receiver, [<<"receiver-entry">>])
        end)
    end}.

actor_failure_hides_only_its_entries_test_() ->
    {timeout, 30, fun() ->
        with_peers(3, fun([A, B, C]) ->
            connect(A, B),
            connect(A, C),
            connect(B, C),
            Source = start(A, <<"source">>, 30),
            Healthy = start(C, <<"healthy">>, 30),
            %% Equal non-object metas still represent two independent refs.
            {ok, _} = track(A, Source, <<"gone">>),
            {ok, _} = track(A, Source, <<"gone">>),
            {ok, _} = track(C, Healthy, <<"healthy">>),
            await_members(B, 2),
            Receiver = start(B, <<"receiver">>, 0),
            {ok, _} = track(B, Receiver, <<"local">>),
            await_view(B, Receiver,
                [<<"gone">>, <<"gone">>, <<"healthy">>, <<"local">>]),
            SourceReplica = call(A, ?MODULE, replica, [Source]),
            nil = call(A, ?MODULE, kill_replica, [Source]),
            await_view(B, Receiver, [<<"healthy">>, <<"local">>]),
            await_diff(B, Receiver, leaves, [<<"gone">>, <<"gone">>]),
            #{clocks := Clocks, entries := 4} =
                call(B, ?MODULE, retained, [Receiver]),
            ?assert(maps:is_key(SourceReplica, Clocks))
        end)
    end}.

node_failure_emits_remote_leaves_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([{Controller, _Node} = A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            Receiver = start(B, <<"receiver">>, 0),
            {ok, _} = track(A, Source, <<"gone">>),
            {ok, _} = track(B, Receiver, <<"local">>),
            await_view(B, Receiver, [<<"gone">>, <<"local">>]),
            ok = peer:cast(Controller, erlang, halt, []),
            await_view(B, Receiver, [<<"local">>]),
            await_diff(B, Receiver, leaves, [<<"gone">>]),
            await_members(B, 1)
        end)
    end}.

partition_retains_history_and_rejoins_current_state_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source">>, 30),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, OldRef} = track(A, Source, <<"before-partition">>),
            {ok, _} = track(B, Receiver, <<"local">>),
            await_view(B, Receiver, [<<"before-partition">>, <<"local">>]),
            SourceReplica = call(A, ?MODULE, replica, [Source]),
            #{clocks := Before} = call(B, ?MODULE, retained, [Receiver]),
            disconnect(A, B),
            await_view(B, Receiver, [<<"local">>]),
            await_diff(B, Receiver, leaves, [<<"before-partition">>]),
            #{clocks := During, entries := 2} =
                call(B, ?MODULE, retained, [Receiver]),
            ?assertEqual(maps:get(SourceReplica, Before),
                         maps:get(SourceReplica, During)),
            {ok, nil} = presence_call(A, untrack, [handle(Source), OldRef]),
            {ok, _} = track(A, Source, <<"after-partition">>),
            connect(A, B),
            await_view(B, Receiver, [<<"after-partition">>, <<"local">>]),
            await_diff(B, Receiver, joins,
                [<<"after-partition">>, <<"before-partition">>, <<"local">>]),
            %% Removing a hidden entry must not emit a second leave; the
            %% reconnect must not first publish the retained, obsolete meta.
            await_diff(B, Receiver, leaves, [<<"before-partition">>]),
            ?assertEqual(SourceReplica, call(A, ?MODULE, replica, [Source]))
        end)
    end}.

%% The control channel is standard I/O, not distribution. Polling a partitioned
%% peer therefore cannot reconnect the nodes under test. Linked controllers and
%% nested after blocks also clean up nodes when boot or an assertion fails.
with_peers(0, Run) ->
    Run([]);
with_peers(Count, Run) ->
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    {ok, Controller, Node} = peer:start_link(#{
        name => peer:random_name("beryl_presence"),
        connection => standard_io,
        peer_down => continue,
        args => ["+S", "2:2", "+A", "1", "-connect_all", "false",
                 "-setcookie", "beryl_presence_distributed_test", "-pa" | Paths]
    }),
    Peer = {Controller, Node},
    try
        _ = presence_pubsub(Peer),
        with_peers(Count - 1, fun(Peers) -> Run([Peer | Peers]) end)
    after
        peer:stop(Controller)
    end.

call({Controller, _Node}, Module, Function, Arguments) ->
    peer:call(Controller, Module, Function, Arguments).

presence_call(Peer, Function, Arguments) ->
    call(Peer, 'beryl@presence', Function, Arguments).

presence_pubsub(Peer) ->
    Config = call(Peer, 'beryl@pubsub', config_with_scope, [?SCOPE]),
    call(Peer, 'beryl@pubsub', start, [Config]).

connect(A, {_Controller, Node} = B) ->
    true = call(A, net_kernel, connect_node, [Node]),
    {_OtherController, OtherNode} = A,
    await({connected, Node}, fun() ->
        lists:member(OtherNode, call(B, erlang, nodes, []))
    end).

disconnect(A, {_Controller, Node} = B) ->
    true = call(A, erlang, disconnect_node, [Node]),
    await_members(A, 1),
    await_members(B, 1),
    ?assertEqual([], call(A, erlang, nodes, [])),
    ?assertEqual([], call(B, erlang, nodes, [])).

start(Peer, Replica, Interval) ->
    call(Peer, ?MODULE, start_replica, [?SCOPE, Replica, Interval]).

start_replica(Scope, Replica, Interval) ->
    PubSub = 'beryl@pubsub':start('beryl@pubsub':config_with_scope(Scope)),
    Collector = spawn(fun() -> collect_diffs([]) end),
    Config0 = 'beryl@presence':default_config(Replica),
    Config1 = 'beryl@presence':with_pubsub(Config0, PubSub),
    Config2 = 'beryl@presence':with_broadcast_interval(Config1, Interval),
    Config = 'beryl@presence':with_on_diff(Config2, fun(Diff) ->
        Collector ! {presence_diff, Diff},
        nil
    end),
    {ok, Presence} = 'beryl@presence':start(Config),
    {ok, Pid} = 'gleam@erlang@process':subject_owner(
        'beryl@presence':subject(Presence)),
    unlink(Pid),
    #{handle => Presence, pid => Pid, collector => Collector}.

handle(#{handle := Presence}) -> Presence.

track(Peer, Instance, Key) ->
    presence_call(Peer, track,
        [handle(Instance), ?TOPIC, Key, Key, 'gleam@json':null()]).

view(#{handle := Presence, pid := Pid}) ->
    {ok, Entries} = 'beryl@presence':list(Presence, ?TOPIC),
    {ok, Count} = 'beryl@presence':count(Presence, ?TOPIC),
    Crdt = element(2, sys:get_state(Pid)),
    Online = 'lattice_presence@presence_state':get_by_topic(Crdt, ?TOPIC),
    #{entries => lists:sort([{Session, Key} ||
                             {presence_entry, Session, Key, _Meta} <- Entries]),
      count => Count,
      crdt => lists:sort([{Session, Key} || {Session, Key, _Meta} <- Online])}.

sync_round(#{pid := Pid}) ->
    %% Inspect the private sync bookkeeping only for an ordered tick barrier.
    {some, Sync} = element(5, sys:get_state(Pid)),
    element(4, Sync).

replica(#{pid := Pid}) ->
    'lattice_presence@presence_state':replica(element(2, sys:get_state(Pid))).

retained(#{pid := Pid}) ->
    Crdt = element(2, sys:get_state(Pid)),
    #{clocks => 'lattice_presence@presence_state':compacted_clocks(Crdt),
      entries => 'lattice_presence@presence_state':entry_count(Crdt)}.

await_round(Peer, Instance) ->
    Before = call(Peer, ?MODULE, sync_round, [Instance]),
    await({quiet_repair_tick, element(2, Peer)}, fun() ->
        call(Peer, ?MODULE, sync_round, [Instance]) > Before
    end).

await_members(Peer, Count) ->
    PubSub = presence_pubsub(Peer),
    await({pg_members, element(2, Peer), Count}, fun() ->
        call(Peer, 'beryl@pubsub', subscriber_count, [PubSub, ?SYNC_TOPIC])
            =:= Count
    end).

await_view(Peer, Instance, Keys) ->
    Entries = lists:sort([{Key, Key} || Key <- Keys]),
    Expected = #{entries => Entries, count => length(Keys), crdt => Entries},
    await({presence_view, element(2, Peer), Keys}, fun() ->
        call(Peer, ?MODULE, view, [Instance]) =:= Expected
    end),
    ?assertEqual(Expected, call(Peer, ?MODULE, view, [Instance])).

await_diff(Peer, Instance, Kind, Keys) ->
    await({presence_diff, element(2, Peer), Kind, Keys}, fun() ->
        History = call(Peer, ?MODULE, diff_history, [Instance]),
        maps:get(Kind, History) =:= lists:sort(Keys)
    end).

await(Phase, Check) ->
    try 'test_helper':wait_until(Check, 5000, 10)
    catch
        error:Reason:Stack -> erlang:raise(error, {Phase, Reason}, Stack)
    end.

kill_replica(#{pid := Pid}) ->
    Monitor = monitor(process, Pid),
    exit(Pid, kill),
    receive {'DOWN', Monitor, process, Pid, killed} -> nil
    after 5000 -> error({presence_did_not_stop, Pid})
    end.

begin_outage(ScopeName) ->
    Scope = binary_to_existing_atom(ScopeName, utf8),
    {dictionary, Dictionary} = process_info(whereis(Scope), dictionary),
    [Supervisor | _] = proplists:get_value('$ancestors', Dictionary),
    ok = sys:suspend(Supervisor),
    _ = beryl_pubsub_test_ffi:kill_scope(Scope),
    Supervisor.

end_outage(Supervisor) ->
    ok = sys:resume(Supervisor),
    nil.

collect_diffs(Diffs) ->
    receive
        {presence_diff, Diff} -> collect_diffs([Diff | Diffs]);
        {take_diffs, Caller, Ref} ->
            Caller ! {Ref, lists:reverse(Diffs)},
            collect_diffs([]);
        {diff_history, Caller, Ref} ->
            Caller ! {Ref, lists:reverse(Diffs)},
            collect_diffs(Diffs)
    end.

take_diffs(#{collector := Collector}) ->
    Ref = make_ref(),
    Collector ! {take_diffs, self(), Ref},
    receive {Ref, Diffs} -> Diffs
    after 5000 -> error(diff_collector_timeout)
    end.

diff_history(#{collector := Collector}) ->
    Ref = make_ref(),
    Collector ! {diff_history, self(), Ref},
    receive
        {Ref, Diffs} ->
            #{joins => diff_keys(Diffs, diff_joins),
              leaves => diff_keys(Diffs, diff_leaves)}
    after 5000 -> error(diff_collector_timeout)
    end.

diff_keys(Diffs, Accessor) ->
    lists:sort([Key || Diff <- Diffs,
        {presence_entry, _Session, Key, _Meta} <-
            apply('beryl@presence', Accessor, [Diff, ?TOPIC])]).
