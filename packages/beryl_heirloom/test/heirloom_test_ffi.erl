-module(heirloom_test_ffi).
-include_lib("eunit/include/eunit.hrl").
-export([send_transfer/3, send_invalid_table_transfer/2,
         check_unnamed_labels/1, assert_unnamed_labels/1, check_invalid_names/0,
         check_recipient_death_during_transfer/1]).
%% Peer entry point and interpreter condition, not public Gleam APIs.
-export([assert_recipient_death_during_transfer/1, race_gate/1]).

-define(RACE_MODULE, beryl_heirloom_ffi).
-define(RACE_CONTROLLER, heirloom_recipient_death_controller).
-define(RACE_RECIPIENT, heirloom_recipient_death_recipient).

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

%% Check runs directly in the peer RPC table owner with a live local recipient.
%% Only <<"recipient-death-race">> gates; <<"configured-heir">> does not.
-spec check_recipient_death_during_transfer(fun((pid()) -> nil)) -> nil.
check_recipient_death_during_transfer(Check) ->
    Paths = [filename:absname(Path) || Path <- code:get_path()],
    {ok, Controller, _Node} = peer:start_link(#{
        name => peer:random_name("beryl_heirloom_recipient_death"),
        host => "localhost",
        connection => standard_io,
        peer_down => continue,
        wait_boot => 10000,
        shutdown => {halt, 5000},
        args => ["+S", "2:2", "+A", "1", "-connect_all", "false",
                 "-setcookie", "heirloom_test", "-pa" | Paths]
    }),
    try
        nil = peer:call(Controller, ?MODULE,
                       assert_recipient_death_during_transfer, [Check], 20000)
    after
        %% The disposable peer owns all interpreter/meta processes, including
        %% any still blocked after setup failure, callback failure or timeout.
        case is_process_alive(Controller) of
            true -> peer:stop(Controller);
            false -> ok
        end
    end.

-spec assert_recipient_death_during_transfer(fun((pid()) -> nil)) -> nil.
assert_recipient_death_during_transfer(Check) ->
    require_race_interpreter(),
    true = register(?RACE_CONTROLLER, self()),
    Recipient = spawn(fun() -> receive stop_recipient -> ok end end),
    try
        true = register(?RACE_RECIPIENT, Recipient),
        install_race_breakpoint(),
        %% No catch: preserve the callback's original assertion and stack.
        nil = Check(Recipient),
        %% OTP swallows condition exceptions as false. Only successful gate
        %% completion may make this fixture pass. The unique PID correlates
        %% evidence within this single-run, isolated peer.
        receive
            {recipient_death_gate, Recipient, killed} -> nil
        after 1000 ->
            error(recipient_death_race_gate_evidence_missing)
        end
    after
        exit(Recipient, kill),
        unregister(?RACE_CONTROLLER)
    end.

require_race_interpreter() ->
    lists:foreach(fun(Module) ->
        case code:ensure_loaded(Module) of
            {module, Module} -> ok;
            Error ->
                error({recipient_death_race_prerequisite,
                       {debugger_component_unavailable, Module, Error}})
        end
    end, [int, dbg_iserver, dbg_ieval, dbg_icmd, dbg_iload]),
    %% int checks the existing BEAM's abstract code and accessible source.
    %% It must not compile a replacement or silently skip this regression.
    case int:interpretable(?RACE_MODULE) of
        true -> ok;
        Error ->
            error({recipient_death_race_prerequisite,
                   {source_and_beam_debug_info_required, ?RACE_MODULE, Error}})
    end.

install_race_breakpoint() ->
    {module, ?RACE_MODULE} = int:i(?RACE_MODULE),
    ok = int:break_in(?RACE_MODULE, transfer_data, 2),
    %% Discover the function's entry from debug info, never a source line
    %% constant. transfer_data/2 has exactly one clause.
    [{{?RACE_MODULE, Line}, _Options}] = int:all_breaks(?RACE_MODULE),
    ok = int:test_at_break(?RACE_MODULE, Line, {?MODULE, race_gate}),
    %% Fence condition installation before the callback enters interpreted code.
    [{{?RACE_MODULE, Line}, [active, _, _, {?MODULE, race_gate}]}] =
        int:all_breaks(?RACE_MODULE),
    ok.

%% Called synchronously by OTP's conditional-breakpoint evaluator, before
%% transfer_data/2's first expression. Returning false continues the same real
%% ets:give_away/3 in the original owner, AFTER its liveness precheck.
-spec race_gate(term()) -> false.
race_gate(Bindings) ->
    case int:get_binding('Data', Bindings) of
        {value, <<"recipient-death-race">>} ->
            Controller = whereis(?RACE_CONTROLLER),
            Recipient = whereis(?RACE_RECIPIENT),
            true = is_pid(Controller),
            true = is_pid(Recipient),
            {value, Table} = int:get_binding('Table', Bindings),
            Controller = ets:info(Table, owner),
            true = is_process_alive(Recipient),
            Monitor = monitor(process, Recipient),
            try
                exit(Recipient, kill),
                receive
                    {'DOWN', Monitor, process, Recipient, killed} ->
                        Controller ! {recipient_death_gate, Recipient, killed}
                after 1000 ->
                    error(recipient_death_race_recipient_down_timeout)
                end
            after
                demonitor(Monitor, [flush])
            end,
            false;
        _ -> false
    end.

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
