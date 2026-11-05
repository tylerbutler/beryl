-module(beryl_presence_state_compatibility_test).
-include_lib("eunit/include/eunit.hrl").

-define(STATE, 'lattice_presence@presence_state').
-define(OWNER, <<"owner">>).
-define(FOREIGN, <<"foreign">>).
-define(THIRD, <<"third">>).
-define(TOPIC, <<"room:compatibility">>).

%% Construct states through upstream APIs. Tuple inspection below is limited
%% to the private representation contract that beryl explicitly depends on.
representation_test() ->
    State = join(cloud_state(?OWNER), <<"same">>),
    {state, ?OWNER, Context, Clouds, Values, Replicas} = State,
    ?assert(is_map(Context)),
    ?assert(is_map(Clouds)),
    ?assert(is_map(Values)),
    ?assert(is_map(Replicas)),
    ?assertEqual(#{?OWNER => up}, Replicas),
    ?assertEqual(#{?OWNER => 4}, ?STATE:compacted_clocks(State)),
    ?assertEqual([3], 'gleam@set':to_list(maps:get(?OWNER, Clouds))),
    [{Tag, Entry}] = maps:to_list(?STATE:internal_values(State)),
    ?assertEqual({tag, ?OWNER, 4}, Tag),
    ?assertMatch({entry, ?TOPIC, <<"same">>, <<"session">>, _}, Entry),
    {Down, _} = ?STATE:replica_down(State, ?OWNER),
    ?assertEqual(#{?OWNER => down}, element(6, Down)),
    ?assertEqual([], ?STATE:online_list(Down)),
    {Up, _} = ?STATE:replica_up(Down, ?OWNER),
    ?assertEqual(State, Up).

exact_removal_preserves_equal_entry_and_other_fields_test() ->
    First = join(cloud_state(?OWNER), <<"same">>),
    Both = join(First, <<"same">>),
    [FirstTag] = maps:keys(?STATE:internal_values(First)),
    [SecondTag] = maps:keys(maps:remove(FirstTag, ?STATE:internal_values(Both))),
    ?assertEqual(maps:get(FirstTag, ?STATE:internal_values(Both)),
        maps:get(SecondTag, ?STATE:internal_values(Both))),
    ?assertEqual(2, length(?STATE:get_by_topic(Both, ?TOPIC))),
    {Removed, true} = beryl_presence_state_ffi:remove_tag(Both, FirstTag),
    ?assertEqual(maps:with([SecondTag], ?STATE:internal_values(Both)),
        ?STATE:internal_values(Removed)),
    ?assertEqual(1, length(?STATE:get_by_topic(Removed, ?TOPIC))),
    assert_non_values_unchanged(Both, Removed).

absent_and_repeated_removal_test() ->
    State = join(cloud_state(?OWNER), <<"same">>),
    [Tag] = maps:keys(?STATE:internal_values(State)),
    ?assertEqual({State, false},
        beryl_presence_state_ffi:remove_tag(State, {tag, ?OWNER, 999})),
    {Removed, true} = beryl_presence_state_ffi:remove_tag(State, Tag),
    ?assertEqual({Removed, false},
        beryl_presence_state_ffi:remove_tag(Removed, Tag)),
    ?assertEqual([], ?STATE:online_list(Removed)),
    assert_non_values_unchanged(State, Removed).

removal_history_blocks_stale_merge_but_allows_later_entry_test() ->
    Stale = join(cloud_state(?OWNER), <<"old">>),
    [Tag] = maps:keys(?STATE:internal_values(Stale)),
    {Removed, true} = beryl_presence_state_ffi:remove_tag(Stale, Tag),
    assert_non_values_unchanged(Stale, Removed),
    %% First receive the old entry, then its removal, then the delayed old
    %% snapshot. Also test a receiver that sees removal before any live value.
    Cached = merge(?STATE:new(<<"cached">>), Stale),
    lists:foreach(fun(Receiver) ->
        AfterRemoval = merge(Receiver, Removed),
        AfterStale = merge(AfterRemoval, Stale),
        ?assertEqual([], ?STATE:get_by_topic(AfterStale, ?TOPIC)),
        Later = join(Removed, <<"later">>),
        Final = merge(AfterStale, Later),
        ?assertEqual(?STATE:get_by_topic(Later, ?TOPIC),
            ?STATE:get_by_topic(Final, ?TOPIC)),
        ?assertEqual(1, ?STATE:entry_count(Final))
    end, [Cached, ?STATE:new(<<"fresh">>)]).

owner_snapshot_projects_values_history_and_status_test() ->
    Own = cloud_state_with_entry(?OWNER),
    Foreign = cloud_state_with_entry(?FOREIGN),
    Combined = merge(Own, Foreign),
    {ForeignDown, _} = ?STATE:replica_down(Combined, ?FOREIGN),
    {AllDown, _} = ?STATE:replica_down(ForeignDown, ?OWNER),
    Snapshot = beryl_presence_state_ffi:owner_snapshot(AllDown),
    ?assertEqual(?OWNER, ?STATE:replica(Snapshot)),
    ?assertEqual(?STATE:internal_values(Own), ?STATE:internal_values(Snapshot)),
    ?assertEqual(?STATE:compacted_clocks(Own), ?STATE:compacted_clocks(Snapshot)),
    ?assertEqual(?STATE:internal_clouds(Own), ?STATE:internal_clouds(Snapshot)),
    ?assertEqual(#{?OWNER => up}, element(6, Snapshot)),
    ?assertEqual(?STATE:online_list(Own), ?STATE:online_list(Snapshot)),
    ?assertEqual(Snapshot, beryl_presence_state_ffi:owner_snapshot(Snapshot)).

empty_owner_snapshot_retains_history_test() ->
    Own = cloud_state_with_entry(?OWNER),
    [Tag] = maps:keys(?STATE:internal_values(Own)),
    {Empty, true} = beryl_presence_state_ffi:remove_tag(Own, Tag),
    Combined = merge(Empty, cloud_state_with_entry(?FOREIGN)),
    Snapshot = beryl_presence_state_ffi:owner_snapshot(Combined),
    ?assertEqual(Empty, Snapshot),
    ?assertEqual([], ?STATE:online_list(Snapshot)),
    ?assertEqual(#{?OWNER => 1}, ?STATE:compacted_clocks(Snapshot)),
    ?assertEqual(1, ?STATE:cloud_count(Snapshot)),
    ?assertEqual(Snapshot, beryl_presence_state_ffi:owner_snapshot(Snapshot)),
    Fresh = merge(?STATE:new(<<"receiver">>), Snapshot),
    ?assertEqual([], ?STATE:online_list(merge(Fresh, Own))),
    ?assertEqual(?STATE:new(?OWNER),
        beryl_presence_state_ffi:owner_snapshot(?STATE:new(?OWNER))).

learned_third_replica_clocks_do_not_suppress_live_entries_test() ->
    Third = cloud_state_with_entry(?THIRD),
    Source = merge(join(cloud_state(?OWNER), <<"own">>), Third),
    ?assert(maps:is_key(?THIRD, ?STATE:internal_clouds(Source))),
    assert_third_survives_projection(Source, Third).

retired_third_replica_clocks_do_not_suppress_live_entries_test() ->
    Third = cloud_state_with_entry(?THIRD),
    Source = merge(join(cloud_state(?OWNER), <<"own">>), Third),
    {Down, _} = ?STATE:replica_down(Source, ?THIRD),
    Retired = ?STATE:remove_down_replica(Down, ?THIRD),
    ?assertEqual(3, maps:get(?THIRD, ?STATE:compacted_clocks(Retired))),
    ?assertNot(maps:is_key(?THIRD, ?STATE:internal_clouds(Retired))),
    ?assertNot(maps:is_key(?THIRD, element(6, Retired))),
    assert_third_survives_projection(Retired, Third).

unsupported_shapes_test_() ->
    State = join(?STATE:new(?OWNER), <<"entry">>),
    BadTuples = [not_a_state, {state}, setelement(1, State, other_state),
        erlang:append_element(State, extra),
        erlang:delete_element(6, State)],
    %% Each required map must fail explicitly in both operations, including
    %% the liveness map that owner_snapshot deliberately replaces.
    BadMaps = [setelement(Index, State, BadMap)
        || Index <- [3, 4, 5, 6], BadMap <- [nil, [], {dict, #{}}]],
    [?_test(begin
        ?assertError(unsupported_lattice_presence_state,
            beryl_presence_state_ffi:remove_tag(Bad, {tag, ?OWNER, 1})),
        ?assertError(unsupported_lattice_presence_state,
            beryl_presence_state_ffi:owner_snapshot(Bad))
    end) || Bad <- BadTuples ++ BadMaps].

join(State, Key) ->
    ?STATE:join(State, <<"session">>, ?TOPIC, Key, 'gleam@json':null()).

merge(Local, Remote) ->
    {ok, Merged} = ?STATE:merge(Local, Remote),
    Merged.

%% The supported upstream decoder creates a real, nonempty Set cloud with a
%% gap at clock 2. Do not fabricate the opaque State or Set representation.
cloud_state(Replica) ->
    decode_cloud_state(Replica, []).

%% Keep a live entry at clock 1 and an uncovered cloud at clock 3. Joining
%% after decoding would allocate clock 4, covering clock 3; the next merge
%% would then legitimately compact the cloud away before projection.
cloud_state_with_entry(Replica) ->
    Value = 'gleam@json':object([
        {<<"tag">>, 'gleam@json':object([
            {<<"replica">>, 'gleam@json':string(Replica)},
            {<<"clock">>, 'gleam@json':int(1)}])},
        {<<"entry">>, 'gleam@json':object([
            {<<"topic">>, 'gleam@json':string(?TOPIC)},
            {<<"key">>, 'gleam@json':string(Replica)},
            {<<"pid">>, 'gleam@json':string(<<"session">>)},
            {<<"meta">>, 'gleam@json':null()}])}
    ]),
    decode_cloud_state(Replica, [Value]).

decode_cloud_state(Replica, Values) ->
    Json = 'gleam@json':object([
        {<<"replica">>, 'gleam@json':string(Replica)},
        {<<"context">>, 'gleam@json':object([{Replica, 'gleam@json':int(1)}])},
        {<<"clouds">>, 'gleam@json':object([
            {Replica, 'gleam@json':array([3], fun 'gleam@json':int/1)}])},
        {<<"values">>, 'gleam@json':preprocessed_array(Values)}
    ]),
    {ok, State} = ?STATE:from_json('gleam@json':to_string(Json)),
    State.

assert_non_values_unchanged(Before, After) ->
    lists:foreach(fun(Index) ->
        ?assertEqual(element(Index, Before), element(Index, After))
    end, [1, 2, 3, 4, 6]).

assert_third_survives_projection(Source, Third) ->
    ?assert(maps:is_key(?THIRD, ?STATE:compacted_clocks(Source))),
    Snapshot = beryl_presence_state_ffi:owner_snapshot(Source),
    ?assertNot(maps:is_key(?THIRD, ?STATE:compacted_clocks(Snapshot))),
    ?assertNot(maps:is_key(?THIRD, ?STATE:internal_clouds(Snapshot))),
    ?assertNot(maps:is_key(?THIRD, element(6, Snapshot))),
    ?assertEqual([], [Tag || {tag, Owner, _} = Tag <-
        maps:keys(?STATE:internal_values(Snapshot)), Owner =/= ?OWNER]),
    %% Deliver the independent third owner's state after the source snapshot.
    %% Leaking either learned history or a retired high-water mark would make
    %% the third entry look already observed and silently discard it.
    Receiver = merge(?STATE:new(<<"receiver">>), Snapshot),
    Final = merge(Receiver, Third),
    ?assertEqual(?STATE:get_by_key(Third, ?TOPIC, ?THIRD),
        ?STATE:get_by_key(Final, ?TOPIC, ?THIRD)),
    ?assertEqual(2, ?STATE:entry_count(Final)).
