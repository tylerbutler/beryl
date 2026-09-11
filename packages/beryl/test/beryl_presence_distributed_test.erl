-module(beryl_presence_distributed_test).
-include_lib("eunit/include/eunit.hrl").
-export([start_replica/3, view/1, sync_round/1, kill_replica/1,
         begin_outage/1, end_outage/1, diff_history/1,
         retained/1, replica/1, crdt/1, request_round/1, pending_request/2,
         start_reply_gate/1, held_reply_count/1, release_replies/1,
         start_lagging_replica/2, start_held_replica/2, legacy_snapshot/1]).

-define(TOPIC, <<"room:distributed">>).
-define(SYNC_TOPIC, <<"beryl:presence:sync">>).
-define(SCOPE, <<"beryl_presence_distributed_test">>).
-define(SOCKET_SCOPE, <<"beryl_presence_socket_frames_test">>).

presence_scope_outage_diffs_stay_on_observing_node_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start_socket_replica(A, <<"source">>),
            Receiver = start_socket_replica(B, <<"receiver">>),
            OtherLocal = call(B, presence_socket_test_helper, start_client, [?SOCKET_SCOPE]),
            ClientA = maps:get(client, Source),
            ClientB = maps:get(client, Receiver),
            Clients = [{A, ClientA}, {B, ClientB}, {B, OtherLocal}],
            lists:foreach(fun({Peer, Client}) -> await_client(Peer, Client) end, Clients),
            lists:foreach(fun(Peer) ->
                Config = call(Peer, 'beryl@pubsub', config_with_scope, [?SOCKET_SCOPE]),
                PubSub = call(Peer, 'beryl@pubsub', start, [Config]),
                await({socket_members, element(2, Peer)}, fun() ->
                    call(Peer, 'beryl@pubsub', subscriber_count, [PubSub, ?TOPIC]) =:= 3
                end)
            end, [A, B]),
            Ref = track_socket_presence(A, Source, <<"healthy-a">>),
            await_view(B, Receiver, [<<"healthy-a">>]),
            lists:foreach(fun({Peer, Client}) ->
                await_frame_barrier(Peer, Client, <<"receiver">>, <<"joins">>,
                    <<"healthy-a">>, Ref, 1)
            end, Clients),
            OriginalJoins = length(diff_frames(client_frames(A, ClientA),
                <<"joins">>, <<"healthy-a">>, Ref)),
            Outage = call(B, ?MODULE, begin_outage, [?SCOPE]),
            try
                await_members(A, 1),
                await_view(B, Receiver, []),
                lists:foreach(fun({Peer, Client}) ->
                    await_frame_barrier(Peer, Client, <<"receiver">>, <<"leaves">>,
                        <<"healthy-a">>, Ref, 1)
                end, Clients),
                %% The healthy source still owns this entry. A receiver's
                %% local pg outage must not send its clients a false leave.
                await_view(A, Source, [<<"healthy-a">>]),
                ?assertEqual([], diff_frames(client_frames(A, ClientA),
                    <<"leaves">>, <<"healthy-a">>, Ref)),
                lists:foreach(fun(Client) ->
                    ?assertEqual(1, length(diff_frames(client_frames(B, Client),
                        <<"leaves">>, <<"healthy-a">>, Ref)))
                end, [ClientB, OtherLocal]),
                %% Application diffs must still cross the healthy socket
                %% PubSub scope while presence replication on B is unavailable.
                NormalRef = track_socket_presence(A, Source, <<"normal">>),
                lists:foreach(fun({Peer, Client}) ->
                    await_frame_barrier(Peer, Client, <<"source">>, <<"joins">>,
                        <<"normal">>, NormalRef, 1),
                    ?assertEqual(1, length(diff_frames(client_frames(Peer, Client),
                        <<"joins">>, <<"normal">>, NormalRef)))
                end, Clients),
                await_view(B, Receiver, []),
                {ok, nil} = presence_call(A, untrack, [handle(Source), NormalRef]),
                lists:foreach(fun({Peer, Client}) ->
                    await_frame_barrier(Peer, Client, <<"source">>, <<"leaves">>,
                        <<"normal">>, NormalRef, 1),
                    ?assertEqual(1, length(diff_frames(client_frames(Peer, Client),
                        <<"leaves">>, <<"normal">>, NormalRef)))
                end, Clients)
            after
                nil = call(B, ?MODULE, end_outage, [Outage])
            end,
            await_view(B, Receiver, [<<"healthy-a">>]),
            lists:foreach(fun({Peer, Client}) ->
                await_frame_barrier(Peer, Client, <<"receiver">>, <<"joins">>,
                    <<"healthy-a">>, Ref, 2)
            end, Clients),
            ?assertEqual(OriginalJoins, length(diff_frames(client_frames(A, ClientA),
                <<"joins">>, <<"healthy-a">>, Ref))),
            ?assertEqual([], diff_frames(client_frames(A, ClientA),
                <<"leaves">>, <<"healthy-a">>, Ref))
        end)
    end}.

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

old_inflight_reply_cannot_evict_replacement_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            {Old, _New, Receiver, Proxy, _CurrentRef} = held_predecessor(A, B),
            ?assert(call(B, ?MODULE, pending_request, [Receiver, maps:get(pid, Old)])),
            nil = call(B, ?MODULE, release_replies, [Proxy]),
            ?assertNot(call(B, ?MODULE, pending_request,
                [Receiver, maps:get(pid, Old)])),
            nil = call(B, ?MODULE, legacy_snapshot, [Receiver]),
            await_view(B, Receiver, [<<"current">>]),
            await_diff(B, Receiver, joins, [<<"current">>]),
            await_diff(B, Receiver, leaves, [])
        end)
    end}.

lagging_peer_cannot_restore_retired_history_test_() ->
    {timeout, 30, fun() ->
        with_peers(3, fun([A, B, C]) ->
            connect(A, B),
            Old = start(A, <<"source">>, 0),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, _} = track(A, Old, <<"old">>),
            await_view(B, Receiver, [<<"old">>]),
            OldState = call(A, ?MODULE, crdt, [Old]),
            OldReplica = call(A, ?MODULE, replica, [Old]),
            nil = call(A, ?MODULE, kill_replica, [Old]),
            Current = start(A, <<"source">>, 0),
            {ok, _} = track(A, Current, <<"current">>),
            await_view(B, Receiver, [<<"current">>]),
            #{clocks := Before} = call(B, ?MODULE, retained, [Receiver]),
            ?assertNot(maps:is_key(OldReplica, Before)),
            %% A third BEAM node speaks the original v2 full-state protocol.
            %% Its valid reply includes a retired replica's values and clocks.
            _LegacyPid = call(C, ?MODULE, start_lagging_replica, [?SCOPE, OldState]),
            connect(B, C),
            await_view(B, Receiver, [<<"current">>, <<"lagging">>]),
            #{clocks := After, entries := 2} =
                call(B, ?MODULE, retained, [Receiver]),
            ?assertNot(maps:is_key(OldReplica, After)),
            await_diff(B, Receiver, leaves, [<<"old">>])
        end)
    end}.

retirement_revokes_old_replies_and_requires_fresh_rejoin_test_() ->
    {timeout, 90, fun() ->
        with_peers(2, fun([A, B]) ->
            {Old, Current, Receiver, Proxy, CurrentRef} = held_predecessor(A, B),
            OldPid = maps:get(pid, Old),
            CurrentReplica = call(A, ?MODULE, replica, [Current]),
            PendingScope = <<"beryl_presence_unconfirmed_retirement_test">>,
            PendingOnly = call(B, ?MODULE, start_replica,
                [PendingScope, <<"pending-only">>, 0]),
            PendingGate = call(B, ?MODULE, start_reply_gate, [PendingOnly]),
            Unconfirmed = call(A, ?MODULE, start_held_replica,
                [PendingScope, PendingGate]),
            UnconfirmedPid = maps:get(pid, Unconfirmed),
            await_member(B, PendingScope, UnconfirmedPid),
            nil = call(B, ?MODULE, request_round, [PendingOnly]),
            await({unconfirmed_reply, element(2, B)}, fun() ->
                call(B, ?MODULE, held_reply_count, [PendingGate]) > 0
            end),
            nil = call(A, ?MODULE, kill_replica, [Unconfirmed]),
            ?assert(call(B, ?MODULE, pending_request, [PendingOnly, UnconfirmedPid])),
            {ok, _} = track(B, Receiver, <<"local">>),
            Started = call(B, erlang, monotonic_time, [millisecond]),
            disconnect(A, B),
            await_view(B, Receiver, [<<"local">>]),
            #{clocks := Retained, entries := 2} =
                call(B, ?MODULE, retained, [Receiver]),
            ?assert(maps:is_key(CurrentReplica, Retained)),
            ?assert(call(B, ?MODULE, pending_request, [Receiver, OldPid])),
            {ok, nil} = presence_call(A, untrack, [handle(Current), CurrentRef]),
            {ok, _} = track(A, Current, <<"after-retention">>),
            %% Exercise the real 60-second policy, including with periodic
            %% requests disabled. No clock rewriting or shortened test TTL.
            await({retirement, element(2, B)}, fun() ->
                #{clocks := Clocks, owners := Owners} =
                    call(B, ?MODULE, retained, [Receiver]),
                Owners =:= 0 andalso not maps:is_key(CurrentReplica, Clocks)
            end, 70000),
            Elapsed = call(B, erlang, monotonic_time, [millisecond]) - Started,
            ?assert(Elapsed >= 60000),
            ?assertNot(call(B, ?MODULE, pending_request, [Receiver, OldPid])),
            ?assertNot(call(B, ?MODULE, pending_request,
                [PendingOnly, UnconfirmedPid])),
            nil = call(B, ?MODULE, release_replies, [PendingGate]),
            await_view(B, PendingOnly, []),
            nil = call(B, ?MODULE, release_replies, [Proxy]),
            await_view(B, Receiver, [<<"local">>]),
            await_diff(B, Receiver, leaves, [<<"current">>]),
            connect(A, B),
            await_member(A, maps:get(pid, Receiver)),
            await_member(B, maps:get(pid, Current)),
            nil = call(A, ?MODULE, request_round, [Current]),
            await_view(B, Receiver, [<<"after-retention">>, <<"local">>]),
            await_diff(B, Receiver, joins,
                [<<"after-retention">>, <<"current">>, <<"local">>]),
            await_diff(B, Receiver, leaves, [<<"current">>]),
            ?assertEqual(CurrentReplica, call(A, ?MODULE, replica, [Current]))
        end)
    end}.

restart_churn_keeps_one_incarnation_per_base_test_() ->
    {timeout, 30, fun() ->
        with_peers(2, fun([A, B]) ->
            connect(A, B),
            Source = start(A, <<"source@slot">>, 0),
            Receiver = start(B, <<"receiver">>, 30),
            {ok, _} = track(A, Source, <<"initial">>),
            await_view(B, Receiver, [<<"initial">>]),
            _Last = lists:foldl(fun(Index, Previous) ->
                nil = call(A, ?MODULE, kill_replica, [Previous]),
                Current = start(A, <<"source@slot">>, 0),
                Key = <<"generation-", (integer_to_binary(Index))/binary>>,
                {ok, _} = track(A, Current, Key),
                await_view(B, Receiver, [Key]),
                #{clocks := Clocks, entries := 1, owners := 1} =
                    call(B, ?MODULE, retained, [Receiver]),
                ?assertEqual(1, map_size(Clocks)),
                Current
            end, Source, lists:seq(1, 8))
        end)
    end}.

held_predecessor(A, B) ->
    %% A protocol peer sends its valid reply into an in-flight gate on B.
    %% The old PID can die before that reply reaches the presence mailbox.
    Receiver = start(B, <<"receiver">>, 0),
    Proxy = call(B, ?MODULE, start_reply_gate, [Receiver]),
    Old = call(A, ?MODULE, start_held_replica, [?SCOPE, Proxy]),
    await({initial_round, element(2, B)}, fun() ->
        call(B, ?MODULE, sync_round, [Receiver]) > 0
    end),
    connect(A, B),
    await_member(A, maps:get(pid, Receiver)),
    await_member(B, maps:get(pid, Old)),
    nil = call(B, ?MODULE, request_round, [Receiver]),
    await({held_old_reply, element(2, B)}, fun() ->
        call(B, ?MODULE, held_reply_count, [Proxy]) > 0
    end),
    nil = call(A, ?MODULE, kill_replica, [Old]),
    Current = start(A, <<"source">>, 0),
    {ok, CurrentRef} = track(A, Current, <<"current">>),
    await_member(B, maps:get(pid, Current)),
    nil = call(A, ?MODULE, request_round, [Current]),
    await_view(B, Receiver, [<<"current">>]),
    {Old, Current, Receiver, Proxy, CurrentRef}.

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
    presence_pubsub(Peer, ?SCOPE).

presence_pubsub(Peer, Scope) ->
    Config = call(Peer, 'beryl@pubsub', config_with_scope, [Scope]),
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

start_socket_replica(Peer, Replica) ->
    Client = call(Peer, presence_socket_test_helper, start_client, [?SOCKET_SCOPE]),
    {Presence, Pid} = call(Peer, presence_socket_test_helper, start_presence,
        [Client, ?SCOPE, Replica]),
    #{handle => Presence, pid => Pid, client => Client}.

track_socket_presence(Peer, Instance, Key) ->
    {ok, Ref} = presence_call(Peer, track,
        [handle(Instance), ?TOPIC, Key, Key, 'gleam@json':object([])]),
    Ref.

client_frames(Peer, Client) ->
    [json:decode(Frame) || Frame <-
        call(Peer, presence_socket_test_helper, frames, [Client])].

await_client(Peer, Client) ->
    await({socket_join, element(2, Peer)}, fun() ->
        lists:any(fun
            ([<<"join">>, <<"join">>, ?TOPIC, <<"phx_reply">>,
              #{<<"status">> := <<"ok">>}]) -> true;
            (_) -> false
        end, client_frames(Peer, Client))
    end).

diff_frames(Frames, Side, Key, Ref) ->
    [Payload || [null, null, ?TOPIC, <<"presence_diff">>, Payload] <- Frames,
        diff_contains_ref(Payload, Side, Key, Ref)].

diff_contains_ref(Payload, Side, Key, Ref) ->
    case maps:find(Key, maps:get(Side, Payload)) of
        {ok, #{<<"metas">> := Metas}} ->
            lists:any(fun(Meta) -> maps:get(<<"phx_ref">>, Meta) =:= Ref end, Metas);
        error -> false
    end.

await_frame_barrier(Peer, Client, Replica, Side, Key, Ref, Count) ->
    await({socket_diff_barrier, element(2, Peer), Replica, Side, Key}, fun() ->
        Markers = [ok ||
            [null, null, ?TOPIC, <<"presence_diff_barrier">>, Marker] <-
                client_frames(Peer, Client),
            maps:get(<<"replica">>, Marker) =:= Replica,
            diff_contains_ref(maps:get(<<"diff">>, Marker), Side, Key, Ref)],
        length(Markers) >= Count
    end).

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

crdt(#{pid := Pid}) ->
    element(2, sys:get_state(Pid)).

retained(#{pid := Pid}) ->
    Actor = sys:get_state(Pid),
    Crdt = element(2, Actor),
    {some, Sync} = element(5, Actor),
    #{clocks => 'lattice_presence@presence_state':compacted_clocks(Crdt),
      entries => 'lattice_presence@presence_state':entry_count(Crdt),
      owners => map_size(element(5, Sync))}.

request_round(#{handle := Presence, pid := Pid}) ->
    'gleam@erlang@process':send('beryl@presence':subject(Presence), broadcast_tick),
    _ = sys:get_state(Pid),
    nil.

pending_request(#{pid := Pid}, Owner) ->
    {some, Sync} = element(5, sys:get_state(Pid)),
    maps:is_key(Owner, element(3, Sync)).

start_reply_gate(#{pid := Pid}) ->
    spawn(fun() -> reply_proxy(Pid, []) end).

reply_proxy(Target, Held) ->
    receive
        {hold_reply, Subject, Reply = {sync_reply, _Request, _Owner, _State}} ->
            reply_proxy(Target, [{Subject, Reply} | Held]);
        {held_reply_count, Caller, Ref} ->
            Caller ! {Ref, length(Held)},
            reply_proxy(Target, Held);
        {release_replies, Caller, Ref} ->
            lists:foreach(fun({Subject, Reply}) ->
                'gleam@erlang@process':send(Subject, Reply)
            end, lists:reverse(Held)),
            %% Same-sender barrier: the target processes the delayed replies
            %% before the test checks its final state and callback history.
            _ = sys:get_state(Target),
            Caller ! {Ref, nil},
            reply_proxy(Target, [])
    end.

held_reply_count(Proxy) -> proxy_call(Proxy, held_reply_count).
release_replies(Proxy) -> proxy_call(Proxy, release_replies).

proxy_call(Proxy, Operation) ->
    Ref = make_ref(),
    Proxy ! {Operation, self(), Ref},
    receive {Ref, Reply} -> Reply
    after 5000 -> error({reply_proxy_timeout, Operation})
    end.

start_lagging_replica(Scope, RemoteState) ->
    Local = 'lattice_presence@presence_state':new(<<"lagging@legacy">>),
    Merged = 'lattice_presence@presence_state':merge(Local, RemoteState),
    State = 'lattice_presence@presence_state':join(
        Merged, <<"lagging">>, ?TOPIC, <<"lagging">>, 'gleam@json':null()),
    start_snapshot_replica(Scope, State, direct).

start_held_replica(Scope, Gate) ->
    Local = 'lattice_presence@presence_state':new(<<"source@held">>),
    State = 'lattice_presence@presence_state':join(
        Local, <<"old">>, ?TOPIC, <<"old">>, 'gleam@json':null()),
    #{pid => start_snapshot_replica(Scope, State, {held, Gate})}.

start_snapshot_replica(Scope, State, Delivery) ->
    Parent = self(),
    Ref = make_ref(),
    Pid = spawn(fun() ->
        PubSub = 'beryl@pubsub':start('beryl@pubsub':config_with_scope(Scope)),
        Subscriber = 'beryl@pubsub':subscriber(PubSub),
        nil = 'beryl@pubsub':join(Subscriber, ?SYNC_TOPIC),
        Parent ! {Ref, ready},
        snapshot_replica(binary_to_existing_atom(Scope, utf8), State, Delivery)
    end),
    receive {Ref, ready} -> Pid
    after 5000 -> error(lagging_replica_start_timeout)
    end.

snapshot_replica(Scope, State, Delivery) ->
    receive
        {Scope, ?SYNC_TOPIC, <<"presence_sync">>,
         {sync_payload, 2, Request, Reply, _RequestBack}, {from_pid, _Sender}} ->
            Snapshot = {sync_reply, Request, self(), State},
            case Delivery of
                direct -> 'gleam@erlang@process':send(Reply, Snapshot);
                {held, Gate} -> Gate ! {hold_reply, Reply, Snapshot}
            end,
            snapshot_replica(Scope, State, Delivery)
    end.

legacy_snapshot(#{pid := Pid}) ->
    State = 'lattice_presence@presence_state':new(<<"source@legacy">>),
    Snapshot = 'lattice_presence@presence_state':join(
        State, <<"legacy">>, ?TOPIC, <<"legacy">>, 'gleam@json':null()),
    nil = beryl_pubsub_ffi:send_to_pid(
        Pid, binary_to_existing_atom(?SCOPE, utf8),
        {message, ?SYNC_TOPIC, <<"presence_sync">>,
         {sync_payload, 1, <<"source@legacy">>, Snapshot}, system}),
    _ = sys:get_state(Pid),
    nil.

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

await_member(Peer, Pid) ->
    await_member(Peer, ?SCOPE, Pid).

await_member(Peer, Scope, Pid) ->
    PubSub = presence_pubsub(Peer, Scope),
    await({pg_member, element(2, Peer), Pid}, fun() ->
        lists:member(Pid,
            call(Peer, 'beryl@pubsub', subscribers, [PubSub, ?SYNC_TOPIC]))
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
    await(Phase, Check, 5000).

await(Phase, Check, Timeout) ->
    try 'test_helper':wait_until(Check, Timeout, 10)
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
        {diff_history, Caller, Ref} ->
            Caller ! {Ref, lists:reverse(Diffs)},
            collect_diffs(Diffs)
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
