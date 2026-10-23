%% Test-only host logger ownership fixture. No Gleam logging dependency exposes
%% primary filters/metadata, complete handler snapshots, or try/after scopes.
%% All callbacks run in the test process; assertion failures propagate after
%% cleanup. Tests using this fixture must run in the serial lane.
-module(beryl_logger_test_ffi).
-export([with_host/2, snapshot/0, with_cleanup/2, receive_log/5,
         receive_supervisor_report/2, assertion_fails/1, log/2]).

-define(HANDLER, beryl_logger_ownership_test).

snapshot() ->
    {logger:get_primary_config(),
     lists:sort(logger:get_handler_config()),
     whereis(logger_std_h_default)}.

with_host(Level, Action) ->
    Original = snapshot(),
    Reference = make_ref(),
    try
        ok = logger:set_primary_config(#{
            level => host_level(Level),
            filter_default => stop,
            filters => [{beryl_host_sentinel, {fun allow/2, Reference}}],
            metadata => #{beryl_host_sentinel => Reference}
        }),
        ok = logger:update_handler_config(default, #{
            level => warning,
            filter_default => stop,
            filters => [{beryl_handler_sentinel, {fun allow/2, Reference}}],
            formatter => {logger_formatter, #{
                single_line => true, template => [level, ": ", msg, "\n"]
            }}
        }),
        ok = logger:add_handler(?HANDLER, ?MODULE, #{
            level => debug,
            config => #{pid => self(), reference => Reference}
        }),
        Action(Reference)
    after
        restore(Original),
        discard_captured(Reference)
    end.

host_level(debug) -> debug;
host_level(info) -> info;
host_level(warn) -> warning;
host_level(error_level) -> error.

allow(Event, _Reference) -> Event.

%% Restore only changed handlers, preserving the identity of untouched host
%% sinks. Also undo handlers accidentally installed by the code under test.
restore({Primary, Handlers, _DefaultPid}) ->
    Ids = [Id || #{id := Id} <- Handlers],
    lists:foreach(fun(Id) ->
        case lists:member(Id, Ids) of
            true -> ok;
            false -> ok = logger:remove_handler(Id)
        end
    end, logger:get_handler_ids()),
    lists:foreach(fun restore_handler/1, Handlers),
    ok = logger:set_primary_config(Primary).

restore_handler(#{id := Id, module := Module} = Config) ->
    Settings = maps:without([id, module], Config),
    case logger:get_handler_config(Id) of
        {ok, Config} -> ok;
        {ok, #{module := Module}} ->
            ok = logger:set_handler_config(Id, Settings);
        {ok, _Other} ->
            ok = logger:remove_handler(Id),
            ok = logger:add_handler(Id, Module, Settings);
        {error, {not_found, Id}} ->
            ok = logger:add_handler(Id, Module, Settings)
    end.

with_cleanup(Cleanup, Action) ->
    try Action()
    after Cleanup()
    end.

%% Used only to prove fixture restoration when a real Gleam assertion fails.
assertion_fails(Action) ->
    try Action() of
        _ -> false
    catch
        error:#{gleam_error := panic, module := <<"gleeunit/should">>} -> true
    end.

%% A reference plus the exact report/message shape isolates each fixture.
%% The Gleam boundary returns booleans, not coerced Erlang report records.
receive_log(Reference, Message, Key, Value, Timeout) ->
    receive
        {beryl_logger_test, Reference, Message, #{Key := Value}} -> true
    after Timeout -> false
    end.

receive_supervisor_report(Reference, Child) ->
    receive
        {beryl_logger_test_supervisor, Reference, Child} -> true
    after 1000 -> false
    end.

log(#{msg := {report, [{palabres, Fields, Message, _}]}},
    #{config := #{pid := Pid, reference := Reference}}) ->
    Metadata = maps:from_list([
        {Key, Value} || {Key, [{string_field, Value} | _]} <- Fields
    ]),
    Pid ! {beryl_logger_test, Reference, Message, Metadata},
    ok;
log(#{msg := {report, #{label := {supervisor, child_terminated},
                       report := Report}}},
    #{config := #{pid := Pid, reference := Reference}}) ->
    Offender = proplists:get_value(offender, Report),
    Child = proplists:get_value(pid, Offender),
    Pid ! {beryl_logger_test_supervisor, Reference, Child},
    ok;
log(_Event, _Config) ->
    ok.

discard_captured(Reference) ->
    receive
        {beryl_logger_test, Reference, _, _} -> discard_captured(Reference);
        {beryl_logger_test_supervisor, Reference, _} -> discard_captured(Reference)
    after 0 -> ok
    end.
