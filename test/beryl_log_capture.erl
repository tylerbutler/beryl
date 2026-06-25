%% Test-only Erlang logger handler that captures palabres log reports and
%% forwards them to a registered test process. Palabres emits its logs as
%% reports of the shape `{palabres, Fields, Message, At}` through the Erlang
%% `logger`; this handler decodes the message and string fields and sends a
%% `{captured_log, Message, Metadata}` tuple to the test pid, where Metadata is a
%% map of `KeyBinary => ValueBinary`. This mirrors the Gleam `CapturedLog`
%% record shape, giving deterministic, in-memory assertions without depending on
%% file output flush timing.
-module(beryl_log_capture).

-export([start/1, stop/0, log/2]).

-define(HANDLER_ID, beryl_log_capture).

%% Install (or reinstall) the capture handler bound to Pid. Idempotent across
%% tests: any previous handler is removed first so each test owns the sink.
start(Pid) ->
    _ = logger:remove_handler(?HANDLER_ID),
    ok = logger:add_handler(?HANDLER_ID, ?MODULE, #{config => #{pid => Pid}}),
    nil.

%% Remove the capture handler.
stop() ->
    _ = logger:remove_handler(?HANDLER_ID),
    nil.

%% Logger handler callback. Only palabres reports are forwarded; everything else
%% is ignored. The forwarded tuple matches the Gleam `CapturedLog` record shape
%% so the test can coerce it directly via `beryl_ffi:identity/1`.
log(#{msg := {report, [{palabres, Fields, Message, _At}]}},
    #{config := #{pid := Pid}}) ->
    Pid ! {captured_log, to_binary(Message), maps:from_list(simplify_fields(Fields))},
    ok;
log(_LogEvent, _Config) ->
    ok.

%% Flatten palabres fields (`[{Key, [Field]}]`) to `[{KeyBin, ValueBin}]`,
%% dropping keys with no values (e.g. the default empty `at`/`when` slots).
simplify_fields(Fields) ->
    lists:filtermap(
        fun({Key, Values}) ->
            case Values of
                [] -> false;
                [Value | _] -> {true, {to_binary(Key), field_to_binary(Value)}}
            end
        end,
        Fields).

field_to_binary({string_field, V}) -> to_binary(V);
field_to_binary({int_field, V}) -> integer_to_binary(V);
field_to_binary({float_field, V}) -> float_to_binary(V);
field_to_binary({bool_field, true}) -> <<"true">>;
field_to_binary({bool_field, false}) -> <<"false">>;
field_to_binary(null_field) -> <<"null">>;
field_to_binary({lazy_field, Fun}) -> field_to_binary(Fun());
field_to_binary(Other) -> to_binary(Other).

to_binary(V) when is_binary(V) -> V;
to_binary(V) when is_list(V) -> unicode:characters_to_binary(V);
to_binary(V) when is_atom(V) -> atom_to_binary(V, utf8);
to_binary(V) -> unicode:characters_to_binary(io_lib:format("~p", [V])).
