-module(heirloom_test_ffi).
-include_lib("eunit/include/eunit.hrl").
-export([send_transfer/3, send_invalid_table_transfer/2,
         check_unnamed_labels/1, assert_unnamed_labels/1, check_invalid_names/0]).

send_transfer(Table, PreviousOwner, Data) ->
    self() ! {'ETS-TRANSFER', Table, PreviousOwner, Data},
    nil.

send_invalid_table_transfer(PreviousOwner, Data) ->
    self() ! {'ETS-TRANSFER', make_ref(), PreviousOwner, Data},
    nil.

check_unnamed_labels(Create) ->
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    {ok, Controller, _Node} = peer:start_link(#{
        name => peer:random_name("beryl_heirloom_labels"),
        host => "localhost",
        connection => standard_io,
        peer_down => continue,
        args => ["+S", "2:2", "+A", "1", "-connect_all", "false",
                 "-setcookie", "heirloom_test", "-pa" | Paths]
    }),
    try
        %% One call keeps creation, observation and deletion in the same owner.
        nil = peer:call(Controller, ?MODULE, assert_unnamed_labels, [Create])
    after
        case is_process_alive(Controller) of
            true -> peer:stop(Controller);
            false -> ok
        end
    end.

assert_unnamed_labels(Create) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    %% Construct only binaries, never atoms, including the multibyte label.
    Labels = [
        <<"heirloom_fresh_ascii_", Suffix/binary>>,
        <<"heirloom_fresh_utf8_", Suffix/binary, 16#00e9/utf8, 16#1f600/utf8>>
    ],
    lists:foreach(fun(Name) ->
        assert_label_not_interned(Name),
        {ok, Table} = Create(Name),
        try
            assert_label_not_interned(Name),
            ?assertEqual(Table, ets:info(Table, id)),
            ?assertEqual(beryl_heirloom, ets:info(Table, name)),
            ?assertEqual(false, ets:info(Table, named_table)),
            ?assertEqual(self(), ets:info(Table, owner)),
            ?assertEqual({ok, nil}, beryl_heirloom_ffi:delete(Table)),
            ?assertEqual(undefined, ets:info(Table)),
            assert_label_not_interned(Name)
        after
            %% If an assertion fails before deletion, clean up the exact TID.
            case ets:info(Table) of
                undefined -> ok;
                _ -> {ok, nil} = beryl_heirloom_ffi:delete(Table)
            end
        end
    end, Labels),
    nil.

assert_label_not_interned(Name) ->
    ?assertError(badarg, binary_to_existing_atom(Name, utf8)).

check_invalid_names() ->
    %% Malformed and incomplete UTF-8 cannot be supplied as Gleam Strings.
    Names = [<<16#ff>>, <<16#c3, 16#28>>, <<16#e2, 16#82>>, 679, "label"],
    lists:foreach(fun(Named) ->
        lists:foreach(fun(Name) ->
            Created = beryl_heirloom_ffi:create(
                Name, set, protected, Named, false, false, no_heir),
            try
                ?assertEqual({error, invalid_name}, Created)
            after
                %% Also clean up if a regression unexpectedly accepts the input.
                case Created of
                    {ok, Table} -> {ok, nil} = beryl_heirloom_ffi:delete(Table);
                    {error, _} -> ok
                end
            end
        end, Names)
    end, [false, true]),
    nil.
