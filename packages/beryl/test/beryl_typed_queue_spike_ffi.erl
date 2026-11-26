-module(beryl_typed_queue_spike_ffi).
-export([new/1, read/1, compare_replace/3, assert_owner/1, name/2, lookup/1,
         structural_bytes/2, key/1, bounded_call/5]).
-export([arm_cas_hook/1, measure/2, run_contracts/0, with_fixtures/1,
         start_app_supervisor/3, request_app_stop/2, table_words/1, legacy_words/1,
         fixture_attach_queue/0]).

-define(CAS_HOOK, {?MODULE, cas_hook}).
-define(CONTRACT_FIXTURE, beryl_typed_work_queue_contract_fixture).
-define(TELEMETRY_FIXTURE, beryl_typed_queue_telemetry_contract_fixture).
-define(APP_FIXTURE, beryl_typed_app_supervisor_fixture).
-define(ATTACH_FIXTURE, beryl_typed_queue_attach_fixture).
-define(HANDLER_TABLE, beryl_typed_queue_fixture_handlers).
-define(FIXTURE_TIMEOUT, 6000).
-define(MAX_REPETITIONS, 1000000).

%% Native primitives --------------------------------------------------------
%% Erlang-only experimental test boundary, not a production queue adapter.
%% State and Queue are exact Gleam-created terms: no native ledger, policy,
%% counters, version increments, or inspection of queue record fields.
%% The caller owns the table; owner exit destroys it (no heir).
new(State) ->
    Table = ets:new(?MODULE, [set, public, {read_concurrency, true}]),
    true = ets:insert(Table, {state, State}),
    Table.

read(Table) ->
    case safe_lookup(Table, state) of
        [{state, State}] -> {ok, State};
        [] -> {error, unavailable}
    end.

%% Before and After may contain any Gleam values, including closures.
%% Literal match-spec constants prevent arbitrary state terms being parsed as
%% match-spec expressions. Retry decisions and all effects belong to Gleam.
compare_replace(Table, Before, After) ->
    Match = [{{state, '$1'},
              [{'=:=', '$1', {const, Before}}],
              [{const, {state, After}}]}],
    run_cas_hook(),
    try ets:select_replace(Table, Match) of
        1 -> {ok, true};
        0 -> {ok, false}
    catch error:badarg:Stack ->
        case ets:info(Table) of
            undefined -> {error, unavailable};
            _ -> erlang:raise(error, badarg, Stack)
        end
    end.

assert_owner(Owner) when is_pid(Owner), Owner =:= self() -> nil;
assert_owner(_) -> erlang:error(queue_operation_requires_owner).

%% Same fixed atom Name and caller-lifetime index as the source implementation.
%% No atoms are created here. Queue is stored and returned without conversion.
name(Queue, Name) ->
    Index = case ets:info(Name, owner) of
        undefined -> ets:new(Name, [named_table, protected, set]);
        Owner when Owner =:= self() -> Name;
        _ -> erlang:error(queue_name_owned_by_another_process)
    end,
    true = ets:insert(Index, {queue, Queue}),
    nil.

lookup(Name) ->
    case safe_lookup(Name, queue) of
        [{queue, Queue}] -> {ok, Queue};
        [] -> {error, unavailable}
    end.

%% Only a missing table is a typed availability failure. Preserve live-table
%% access errors and defects, including their original exception stack.
safe_lookup(Table, Key) ->
    try ets:lookup(Table, Key)
    catch error:badarg:Stack ->
        case ets:info(Table) of
            undefined -> [];
            _ -> erlang:raise(error, badarg, Stack)
        end
    end.

%% Opaque CleanupKey, NOT an identity cast into a Gleam custom constructor.
%% Typed callers cannot unseal the generic value; exact Erlang term equality
%% and hashing still distinguish arbitrary keys in a typed Gleam Dict.
key(Value) -> {queue_key, Value}.

%% Source bounded_call/5 transport, with only Owner extracted on the Gleam
%% side. Publish(constructed_message) -> {ok, reference} | {error, error}.
%% Cancel(reference) -> nil is supplied by the typed pending-only policy.
%% Admission failures are wrapped; callback exceptions remain process failures.
%% Timeout starts AFTER publication, exactly as in the production transport.
bounded_call(Owner, Timeout, Request, Publish, CancelPending) ->
    Alias = erlang:alias([reply]),
    Tag = make_ref(),
    Reply = fun(Value) -> Alias ! {Tag, Value}, nil end,
    try
        case Publish(Request(Reply)) of
            {error, Error} -> {error, {admission_rejected, Error}};
            {ok, Id} ->
                Monitor = erlang:monitor(process, Owner),
                try
                    receive
                        {Tag, Value} -> {ok, Value};
                        {'DOWN', Monitor, process, Owner, _} -> {error, owner_unavailable}
                    after max(0, Timeout) ->
                        CancelPending(Id),
                        {error, request_timed_out}
                    end
                after
                    erlang:demonitor(Monitor, [flush])
                end
        end
    after
        erlang:unalias(Alias),
        receive {Tag, _} -> ok after 0 -> ok end
    end.

structural_bytes(Value, Limit) when is_integer(Limit), Limit >= 0 ->
    payload_bytes([Value], 0, Limit).

%% Structural accounting, not heap size. In particular, do not open an app's
%% sealed functions or traverse their captured model/typed-message environment.
%% The three walkers below are copied unchanged from beryl_work_queue_ffi.
payload_bytes(_, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_bytes([], Bytes, _) -> Bytes;
payload_bytes([Value | Rest], Bytes, Limit) when is_bitstring(Value) ->
    payload_bytes(Rest, Bytes + binary:referenced_byte_size(Value), Limit);
payload_bytes([[] | Rest], Bytes, Limit) ->
    payload_bytes(Rest, Bytes + 8, Limit);
payload_bytes([[Head | Tail] | Rest], Bytes, Limit) ->
    payload_bytes([Head, Tail | Rest], Bytes + 16, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_tuple(Value) ->
    payload_tuple(Value, 1, Rest, Bytes + 8, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_map(Value) ->
    payload_map(maps:iterator(Value), Rest, Bytes + 16, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_integer(Value) ->
    payload_bytes(Rest, Bytes + max(8, erlang:external_size(Value)), Limit);
payload_bytes([_ | Rest], Bytes, Limit) ->
    payload_bytes(Rest, Bytes + 8, Limit).

payload_tuple(_, _, _, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_tuple(Value, Index, Rest, Bytes, Limit) when Index > tuple_size(Value) ->
    payload_bytes(Rest, Bytes, Limit);
payload_tuple(Value, Index, Rest, Bytes, Limit) ->
    Next = payload_bytes([element(Index, Value)], Bytes, Limit),
    payload_tuple(Value, Index + 1, Rest, Next, Limit).

payload_map(_, _, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_map(Iterator, Rest, Bytes, Limit) ->
    case maps:next(Iterator) of
        none -> payload_bytes(Rest, Bytes, Limit);
        {Key, Value, Next} ->
            Used = payload_bytes([Key, Value], Bytes + 16, Limit),
            payload_map(Next, Rest, Used, Limit)
    end.

%% Test instrumentation -----------------------------------------------------
%% None of this section participates in the typed ledger's policy. Fixtures
%% are node-wide code: the parent must use an isolated, serial suite, and stop
%% all fixture actors/producers before its Action returns (also on failure).
arm_cas_hook(Hook) when is_function(Hook, 0) ->
    put(?CAS_HOOK, Hook),
    nil.

%% Erase BEFORE invocation: recursive CAS in Hook cannot invoke it again.
%% Per-process only; never consult a global hook or a production module.
run_cas_hook() ->
    case erase(?CAS_HOOK) of
        undefined -> nil;
        Hook -> Hook()
    end.

%% Benchmark-only stored ETS words, including table overhead; not RSS,
%% structural payload bytes, or allocations per update. The parent keeps the
%% owner alive while sampling. A missing table is a fixture failure, not zero.
table_words(Table) ->
    case ets:info(Table, memory) of
        Words when is_integer(Words) -> Words;
        undefined -> erlang:error(benchmark_table_unavailable)
    end.

%% Only instrumentation knows the legacy seven-tuple queue representation.
%% Typed callers expose their table through a test-only Gleam wrapper instead.
legacy_words({Table, _, _, _, _, _, _}) ->
    table_words(Table).

%% Measures only the supplied action in the caller, including loop overhead.
%% Returns {elapsed_microseconds, caller_reduction_delta}. No GC metric:
%% minor_gcs resets on full sweeps and is not a reliable collection delta.
%% No per-update allocation, RSS, or cross-process reduction claims are made.
measure(Action, Repetitions)
        when is_function(Action, 0), is_integer(Repetitions),
             Repetitions >= 0, Repetitions =< ?MAX_REPETITIONS ->
    {reductions, BeforeReductions} = process_info(self(), reductions),
    BeforeTime = erlang:monotonic_time(microsecond),
    repeat(Action, Repetitions),
    Elapsed = erlang:monotonic_time(microsecond) - BeforeTime,
    {reductions, AfterReductions} = process_info(self(), reductions),
    {Elapsed, AfterReductions - BeforeReductions};
measure(Action, _) when is_function(Action, 0) ->
    erlang:error(measurement_repetitions_out_of_range).

repeat(_, 0) -> nil;
repeat(Action, Remaining) ->
    nil = Action(),
    repeat(Action, Remaining - 1).

%% Delegate unchanged actor logic; all callback and message records retain
%% their original tags and layout. No supervisor or stop protocol is rewritten.
start_app_supervisor(Name, StopRuntime, StartSupervisor) ->
    ?APP_FIXTURE:start(Name, StopRuntime, StartSupervisor).

request_app_stop(Name, Finished) ->
    ?APP_FIXTURE:request_stop(Name, Finished).

with_fixtures(Action) when is_function(Action, 0) ->
    try
        with_binary_clone(?ATTACH_FIXTURE, attach_fixture_binary(), fun() ->
            telemetry_cleanup_self_check(),
            with_handler_scope(fun() ->
                with_clone('beryl@app_supervisor', ?APP_FIXTURE, fun() ->
                    with_clone(work_queue_test, ?CONTRACT_FIXTURE, fun() ->
                        with_clone(beryl_telemetry_test, ?TELEMETRY_FIXTURE, Action)
                    end)
                end)
            end)
        end)
    after
        erase(?CAS_HOOK)
    end.

%% Original attach_queue allocates {beryl_queue_test, make_ref()} internally.
%% A return-value wrapper cannot track it if the attaching caller is killed.
%% Instead the custodian owns the table and records our exact ID BEFORE
%% invoking the original handler body with that ID and caller. Scope-owner
%% death cannot destroy the cleanup ledger.
%% Serializing attach and shutdown also prevents an in-flight telemetry server
%% insert from overtaking cleanup. No unrelated IDs are detached.
fixture_attach_queue() ->
    fixture_attach_queue({beryl_queue_test, make_ref()}).

fixture_attach_queue(Id) ->
    fixture_attach_queue(Id, none).

fixture_attach_queue(Id, Observation) ->
    [{custodian, Custodian}] = ets:lookup(?HANDLER_TABLE, custodian),
    Id = fixture_resource_call(Custodian, {attach, Id, self(), Observation}),
    Id.

with_handler_scope(Action) ->
    Owner = self(),
    StartupAlias = erlang:alias([reply]),
    StartupTag = make_ref(),
    {Custodian, Monitor} = spawn_monitor(fun() ->
        OwnerMonitor = erlang:monitor(process, Owner),
        Table = ets:new(?HANDLER_TABLE, [named_table, set, protected]),
        true = ets:insert(Table, {custodian, self()}),
        try
            StartupAlias ! {StartupTag, ready},
            handler_custodian(Table, Owner, OwnerMonitor)
        after
            try detach_tracked_handlers(Table)
            after
                true = ets:delete(Table),
                erlang:demonitor(OwnerMonitor, [flush])
            end
        end
    end),
    try
        Startup = receive
            {StartupTag, ready} -> ready;
            {'DOWN', Monitor, process, Custodian, StartupReason} -> {down, StartupReason}
        after ?FIXTURE_TIMEOUT -> timed_out
        end,
        case Startup of
            {down, Failure} ->
                erlang:error({telemetry_fixture_start_failed, Failure});
            _ ->
                try
                    case Startup of
                        ready -> nil = Action();
                        timed_out -> erlang:error(telemetry_fixture_start_timeout)
                    end
                after
                    %% Only the custodian closes discovery/deletes the ledger.
                    %% On timeout it remains alive, monitoring this owner and
                    %% retaining all IDs until its pending operation/cleanup
                    %% completes. Never kill it to manufacture successful stop.
                    Custodian ! {fixture_stop, Owner},
                    await_fixture_down(Custodian, Monitor)
                end
        end
    after
        erlang:unalias(StartupAlias),
        receive {StartupTag, ready} -> ok after 0 -> ok end,
        case erlang:is_process_alive(Custodian) of
            false -> erlang:demonitor(Monitor, [flush]);
            true -> ok
        end
    end.

handler_custodian(Table, Owner, OwnerMonitor) ->
    receive
        {fixture_resource, Alias, Tag, {attach, Id, Caller, Observation}} ->
            true = ets:insert(Table, {Id, Caller}),
            Id = ?ATTACH_FIXTURE:attach_queue(Id, Caller),
            observe_attachment(Observation, Id),
            Alias ! {Tag, Id},
            handler_custodian(Table, Owner, OwnerMonitor);
        {fixture_stop, Owner} ->
            true = ets:delete(Table, custodian),
            nil;
        {'DOWN', OwnerMonitor, process, Owner, _} ->
            true = ets:delete(Table, custodian),
            nil
    end.

%% Self-check-only gate AFTER attachment but BEFORE replying to the attaching
%% child. Killing that child here exercises the original attach/track gap.
observe_attachment(none, _) -> nil;
observe_attachment({Alias, Tag}, Id) ->
    Alias ! {Tag, attached, Id},
    receive {Tag, continue} -> nil
    after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_gate_timeout)
    end.

fixture_resource_call(Custodian, Request) ->
    Alias = erlang:alias([reply]),
    Tag = make_ref(),
    Monitor = erlang:monitor(process, Custodian),
    try
        Custodian ! {fixture_resource, Alias, Tag, Request},
        receive
            {Tag, Reply} -> Reply;
            {'DOWN', Monitor, process, Custodian, Reason} ->
                erlang:error({telemetry_fixture_custodian_down, Reason})
        after ?FIXTURE_TIMEOUT ->
            erlang:error(telemetry_fixture_custodian_timeout)
        end
    after
        erlang:demonitor(Monitor, [flush]),
        erlang:unalias(Alias),
        receive {Tag, _} -> ok after 0 -> ok end
    end.

await_fixture_down(Pid, Monitor) ->
    receive
        {'DOWN', Monitor, process, Pid, normal} -> nil;
        {'DOWN', Monitor, process, Pid, Reason} ->
            erlang:error({telemetry_fixture_child_down, Reason})
    after ?FIXTURE_TIMEOUT ->
        erlang:error({telemetry_fixture_shutdown_timeout, Pid, Monitor})
    end.

detach_tracked_handlers(Table) ->
    %% Executed only by the table-owning custodian, including on scope-owner
    %% death. Keep the ledger alive while telemetry is temporarily blocked.
    lists:foreach(fun
        ({Id = {beryl_queue_test, _}, _Caller}) -> detach_fixture_handler(Id);
        ({custodian, _}) -> ok
    end, ets:tab2list(Table)),
    nil.

detach_fixture_handler(Id) ->
    try telemetry:detach(Id) of
        ok -> ok;
        {error, not_found} -> ok
    catch
        %% A queued detach may complete after gen_server's call timeout.
        %% Retry only this precise transport failure, from the same custodian,
        %% preserving ordering with its earlier attach. Other defects surface.
        exit:{timeout, {gen_server, call, _}} ->
            receive after 100 -> detach_fixture_handler(Id) end
    end.

%% Bounded native self-check, automatically executed by with_fixtures before
%% loading the generated contract clones. Each scope verifies exact ID removal:
%% an assertion-style failure after attachment, a killed attaching child, and
%% a killed scope owner with its custodian observed through terminal DOWN.
%% No replacement assertion API, handler, or node-wide handler sweep is used.
telemetry_cleanup_self_check() ->
    FailedId = {beryl_queue_test, make_ref()},
    try
        with_handler_scope(fun() ->
            telemetry_cleanup_child(FailedId, fail),
            erlang:error(expected_telemetry_fixture_failure)
        end)
    catch error:expected_telemetry_fixture_failure -> ok
    end,
    assert_handler_removed(FailedId),
    KilledId = {beryl_queue_test, make_ref()},
    with_handler_scope(fun() -> telemetry_cleanup_child(KilledId, kill) end),
    assert_handler_removed(KilledId),
    telemetry_cleanup_owner_kill(),
    nil.

telemetry_cleanup_owner_kill() ->
    Id = {beryl_queue_test, make_ref()},
    Alias = erlang:alias([reply]),
    Tag = make_ref(),
    {Owner, OwnerMonitor} = spawn_monitor(fun() ->
        with_handler_scope(fun() ->
            Id = fixture_attach_queue(Id),
            [{custodian, Custodian}] = ets:lookup(?HANDLER_TABLE, custodian),
            Alias ! {Tag, Custodian},
            receive {Tag, stop} -> nil end
        end)
    end),
    try
        Custodian = receive {Tag, Pid} -> Pid
        after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_owner_attach_timeout)
        end,
        CustodianMonitor = erlang:monitor(process, Custodian),
        try
            exit(Owner, kill),
            receive {'DOWN', OwnerMonitor, process, Owner, killed} -> ok
            after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_owner_kill_timeout)
            end,
            await_fixture_down(Custodian, CustodianMonitor),
            assert_handler_removed(Id),
            undefined = ets:info(?HANDLER_TABLE),
            nil
        after
            case erlang:is_process_alive(Custodian) of
                false -> erlang:demonitor(CustodianMonitor, [flush]);
                true -> ok
            end
        end
    after
        CleanupMonitor = erlang:monitor(process, Owner),
        exit(Owner, kill),
        try
            receive {'DOWN', CleanupMonitor, process, Owner, _} -> ok
            after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_owner_shutdown_timeout)
            end
        after
            erlang:demonitor(CleanupMonitor, [flush]),
            erlang:demonitor(OwnerMonitor, [flush]),
            erlang:unalias(Alias),
            receive {Tag, _} -> ok after 0 -> ok end
        end
    end.

telemetry_cleanup_child(Id, Mode) ->
    Parent = self(),
    Tag = make_ref(),
    ObservationAlias = erlang:alias([reply]),
    [{custodian, Custodian}] = ets:lookup(?HANDLER_TABLE, custodian),
    Observation = case Mode of
        fail -> none;
        kill -> {ObservationAlias, Tag}
    end,
    {Child, Monitor} = spawn_monitor(fun() ->
        Id = fixture_attach_queue(Id, Observation),
        Parent ! {Tag, Id},
        case Mode of
            fail -> erlang:error(expected_telemetry_child_failure);
            kill -> receive {Tag, stop} -> nil end
        end
    end),
    try
        case Mode of
            fail ->
                receive {Tag, Id} -> ok
                after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_attach_timeout)
                end;
            kill ->
                receive {Tag, attached, Id} -> ok
                after ?FIXTURE_TIMEOUT -> erlang:error(telemetry_fixture_attach_timeout)
                end
        end,
        true = lists:any(fun(#{id := HandlerId}) -> HandlerId =:= Id end,
                         telemetry:list_handlers([beryl, queue, occupancy])),
        case Mode of
            fail ->
                receive
                    {'DOWN', Monitor, process, Child,
                     {expected_telemetry_child_failure, _Stack}} -> nil
                after ?FIXTURE_TIMEOUT ->
                    erlang:error(telemetry_fixture_failure_timeout)
                end;
            kill ->
                exit(Child, kill),
                receive {'DOWN', Monitor, process, Child, killed} -> nil
                after ?FIXTURE_TIMEOUT ->
                    erlang:error(telemetry_fixture_kill_timeout)
                end
        end
    after
        case Mode of
            fail -> ok;
            kill -> Custodian ! {Tag, continue}
        end,
        erlang:unalias(ObservationAlias),
        receive {Tag, attached, Id} -> ok after 0 -> ok end,
        %% A fresh monitor also works when the expected DOWN was consumed.
        CleanupMonitor = erlang:monitor(process, Child),
        exit(Child, kill),
        try
            receive {'DOWN', CleanupMonitor, process, Child, _} -> ok
            after ?FIXTURE_TIMEOUT ->
                erlang:error(telemetry_fixture_child_shutdown_timeout)
            end
        after
            erlang:demonitor(CleanupMonitor, [flush]),
            erlang:demonitor(Monitor, [flush]),
            receive {Tag, Id} -> ok after 0 -> ok end
        end
    end.

assert_handler_removed(Id) ->
    false = lists:any(fun(#{id := HandlerId}) -> HandlerId =:= Id end,
                      telemetry:list_handlers([beryl, queue, occupancy])),
    nil.

%% Keep the ACTUAL test FFI handler and its exact mailbox shapes. Only lift
%% the first two bindings into arguments: HandlerId = ..., Owner = self().
%% This test-only native clone has one function, not a rewritten handler.
attach_fixture_binary() ->
    Forms = attach_source_forms(),
    {function, Line, attach_queue, 0,
     [{clause, ClauseLine, [], [],
       [{match, _, {var, _, 'HandlerId'},
         {tuple, _, [{atom, _, beryl_queue_test}, {call, _, {atom, _, make_ref}, []}]}},
        {match, _, {var, _, 'Owner'}, {call, _, {atom, _, self}, []}} | Body]}]} =
        lists:keyfind(attach_queue, 3, Forms),
    Lifted = {function, Line, attach_queue, 2,
              [{clause, ClauseLine, [{var, Line, 'HandlerId'}, {var, Line, 'Owner'}],
                [], Body}]},
    {ok, ?ATTACH_FIXTURE, Binary} =
        compile:forms([{attribute, 0, module, ?ATTACH_FIXTURE},
                       {attribute, 0, export, [{attach_queue, 2}]}, Lifted],
                      [binary, warnings_as_errors]),
    Binary.

attach_source_forms() ->
    case code:which(beryl_telemetry_test_ffi) of
        Beam when is_list(Beam) ->
            case beam_lib:chunks(Beam, [abstract_code]) of
                {ok, {beryl_telemetry_test_ffi,
                      [{abstract_code, {raw_abstract_v1, Forms}}]}} -> Forms;
                _ -> parse_attach_source()
            end;
        _ -> parse_attach_source()
    end.

parse_attach_source() ->
    Paths = ["test/beryl_telemetry_test_ffi.erl",
             "packages/beryl/test/beryl_telemetry_test_ffi.erl"],
    case lists:filter(fun filelib:is_regular/1, Paths) of
        [Path | _] ->
            {ok, Forms} = epp:parse_file(Path, [], []),
            Forms;
        [] -> erlang:error({telemetry_fixture_source_unavailable, Paths})
    end.

%% with_fixtures alone owns the node-wide clone lifetime. Its Action may run
%% these contracts in a separate isolated caller; no process-local marker or
%% nested clone is needed. The parent must keep the fixture scope alive.
run_contracts() ->
    run_contract_set(?CONTRACT_FIXTURE, contract_tests()),
    %% Reuse the actual handler, exact mailbox assertions, and detach logic.
    %% These serial contracts validate enabled and disabled typed queue events.
    run_contract_set(?TELEMETRY_FIXTURE,
                     [queue_events_match_admission_and_cancellation_test,
                      disabled_queue_does_not_emit_test]).

run_contract_set(Fixture, Tests) ->
    case code:is_loaded(Fixture) of
        false -> erlang:error({queue_fixture_not_loaded, Fixture});
        {file, _} -> ok
    end,
    lists:foreach(fun(Test) ->
        case erlang:function_exported(Fixture, Test, 0) of
            true -> nil = apply(Fixture, Test, []);
            false -> erlang:error({missing_queue_contract, Test})
        end
    end, Tests),
    nil.

contract_tests() ->
    [reservation_survives_dequeue_test,
     cancel_pending_preserves_fifo_test,
     wake_is_coalesced_test,
     closed_queue_drains_but_rejects_new_work_test,
     output_after_close_still_obeys_aggregate_limits_test,
     retained_resize_cannot_exceed_aggregate_bytes_test,
     cleanup_is_reserved_and_coalesced_under_saturation_test,
     timeout_then_caller_exit_keeps_cleanup_discoverable_test,
     abandoned_provisional_resource_is_cleaned_once_test,
     concurrent_publication_obeys_both_limits_test,
     producer_crash_after_publication_does_not_lose_work_test,
     published_report_survives_producer_cleanup_test,
     normal_close_ignores_late_closed_then_records_overload_once_test,
     admission_close_preserves_first_error_for_all_variants_test,
     normal_close_can_record_unavailable_or_item_too_large_test,
     sub_binary_is_charged_for_its_backing_allocation_test,
     unaligned_sub_binary_is_charged_for_its_backing_allocation_test].

%% Never overwrite/hot-replace an original (or an existing fixture). Each
%% successfully loaded clone has its own try/after, including partial setup.
with_clone(Module, Clone, Action) ->
    Binary = clone_generated(Module, Clone, 'beryl@typed_work_queue'),
    with_binary_clone(Clone, Binary, Action).

with_binary_clone(Clone, Binary, Action) ->
    case code:is_loaded(Clone) of
        false -> ok;
        _ -> erlang:error({queue_fixture_already_loaded, Clone})
    end,
    {module, Clone} = code:load_binary(Clone, "typed-queue-spike-fixture", Binary),
    try
        nil = Action()
    after
        case Clone of
            ?ATTACH_FIXTURE ->
                case ets:info(?HANDLER_TABLE, owner) of
                    undefined -> delete_clone(Clone);
                    Custodian ->
                        %% Purging this clone while an attach is blocked could
                        %% kill the cleanup guardian. On teardown failure retain
                        %% the code as well as the guardian's ledger; report the
                        %% PID explicitly. Safe code cleanup must wait for DOWN.
                        erlang:error({telemetry_fixture_teardown_pending, Custodian})
                end;
            _ -> delete_clone(Clone)
        end
    end.

delete_clone(Clone) ->
    try code:delete(Clone)
    after code:purge(Clone)
    end.

clone_generated(Module, Clone, Replacement) ->
    Forms = generated_forms(Module),
    Cloned = rewrite(Forms, Module, Clone, Replacement),
    case compile:forms(Cloned, [binary, return_errors, return_warnings]) of
        {ok, Clone, Binary} -> Binary;
        {ok, Clone, Binary, []} -> Binary;
        {ok, Clone, _, Warnings} ->
            erlang:error({queue_fixture_compile_warnings, Module, Warnings});
        {error, Errors, Warnings} ->
            erlang:error({queue_fixture_compile_failed, Module, Errors, Warnings})
    end.

%% Generated Gleam inlines @external calls directly to beryl_work_queue_ffi.
%% Redirect THOSE remote calls and external fun captures too, preserving
%% function names/arities. This is
%% essential: changing only beryl@work_queue would silently test native policy.
%% All original module atoms (including self references and type specs) become
%% Clone; ordinary data constructor atoms and generic values remain untouched.
rewrite({remote, Line, {atom, AtomLine, beryl_work_queue_ffi}, Function},
        Module, Clone, Replacement) ->
    {remote, Line, {atom, AtomLine, Replacement},
     rewrite(Function, Module, Clone, Replacement)};
rewrite({remote, Line, {atom, AtomLine, beryl_telemetry_test_ffi},
         {atom, FunctionLine, attach_queue}}, _, _, _) ->
    {remote, Line, {atom, AtomLine, ?MODULE}, {atom, FunctionLine, fixture_attach_queue}};
rewrite(Module, Module, Clone, _) -> Clone;
rewrite('beryl@work_queue', _, _, Replacement) -> Replacement;
rewrite(beryl_work_queue_ffi, _, _, Replacement) -> Replacement;
rewrite(Tuple, Module, Clone, Replacement) when is_tuple(Tuple) ->
    list_to_tuple([rewrite(Value, Module, Clone, Replacement)
                   || Value <- tuple_to_list(Tuple)]);
rewrite(List, Module, Clone, Replacement) when is_list(List) ->
    [rewrite(Value, Module, Clone, Replacement) || Value <- List];
rewrite(Value, _, _, _) -> Value.

%% Prefer actual BEAM abstract code. Gleam .abstr files are trusted local
%% build artefacts encoded as an Erlang external term (a list of forms), not
%% textual .erl files. Never compile production Erlang policy as a fixture.
generated_forms(Module) ->
    case code:which(Module) of
        Beam when is_list(Beam) ->
            case beam_lib:chunks(Beam, [abstract_code]) of
                {ok, {Module, [{abstract_code, {raw_abstract_v1, Forms}}]}} -> Forms;
                BeamFailure -> generated_abstr(Module, Beam, BeamFailure)
            end;
        Status -> generated_abstr(Module, [], {beam_unavailable, Status})
    end.

generated_abstr(Module, Beam, BeamFailure) ->
    Filename = atom_to_list(Module) ++ ".abstr",
    Paths = case Beam of
        [] -> [];
        [_ | _] ->
            [filename:join([filename:dirname(filename:dirname(Beam)),
                            "_gleam_artefacts", Filename])]
    end,
    Candidates = Paths ++
        [filename:join(["build", "dev", "erlang", "beryl",
                        "_gleam_artefacts", Filename]),
         filename:join(["packages", "beryl", "build", "dev", "erlang",
                        "beryl", "_gleam_artefacts", Filename])],
    read_abstr(Candidates, Module, BeamFailure, []).

read_abstr([], Module, BeamFailure, Failures) ->
    erlang:error({queue_fixture_abstract_code_unavailable, Module,
                  BeamFailure, lists:reverse(Failures)});
read_abstr([Path | Rest], Module, BeamFailure, Failures) ->
    case file:read_file(Path) of
        {ok, Binary} ->
            %% Decoding defects remain explicit failures, never fake forms.
            case binary_to_term(Binary) of
                Forms when is_list(Forms) ->
                    case lists:keyfind(module, 3, Forms) of
                        {attribute, _, module, Module} -> Forms;
                        Other -> erlang:error({queue_fixture_wrong_module, Path, Other})
                    end;
                _ -> erlang:error({queue_fixture_invalid_abstr, Path})
            end;
        {error, Reason} ->
            read_abstr(Rest, Module, BeamFailure, [{Path, Reason} | Failures])
    end.
