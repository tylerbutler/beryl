-module(beryl_diagnostic_test_ffi).
-export([rescue_description/2, abnormal_exit_description/1,
         referenced_byte_size/1, retained_slice/0,
         fail_operation/1, fail_with_stack/1, fail_exception/2]).

fail_operation(Value) ->
    _ = binary_to_integer(Value),
    nil.

fail_with_stack(Shape) ->
    Frame = {diagnostic_app, update, [<<"private-request-payload">>],
             [{file, "src/diagnostic_app.gleam"}, {line, 42},
              {error_info, #{cause => <<"private-stack-metadata">>}}]},
    Stack = case Shape of
        <<"fun">> ->
            [{fun retained_slice/0, [], []}];
        <<"long_location">> ->
            [{diagnostic_app, update, 2,
              [{file, lists:duplicate(200000, 16#1f680)}, {line, 42}]}];
        <<"long_names">> ->
            [{diagnostic_application_with_a_deliberately_long_module_name,
              callback_with_a_deliberately_long_function_name, 2,
              [{file, "diagnostic_app.gleam"}, {line, 42}]}];
        <<"invalid_location">> ->
            [{diagnostic_app, update, 2,
              [{file, [bad, 16#d800, 10]}, {line, 42}]}];
        _ -> lists:duplicate(64, Frame)
    end,
    erlang:raise(error, reason(Shape), Stack).

retained_slice() ->
    binary:part(binary:copy(<<$x>>, 8 * 1024 * 1024), 0, 128).

rescue_description(Class, Shape) ->
    rescue(fun() -> fail_exception(Class, Shape) end).

fail_exception(<<"error">>, Shape) -> erlang:error(reason(Shape));
fail_exception(<<"exit">>, Shape) -> erlang:exit(reason(Shape));
fail_exception(<<"throw">>, Shape) -> erlang:throw(reason(Shape)).

abnormal_exit_description(Shape) ->
    beryl_error_ffi:describe_abnormal_exit({abnormal, reason(Shape)}).

referenced_byte_size(Binary) ->
    binary:referenced_byte_size(Binary).

rescue(Fun) ->
    {error, Description} = beryl_ffi:rescue(Fun),
    Description.

reason(<<"small">>) ->
    <<"boom">>;
reason(<<"flat">>) ->
    lists:duplicate(2000000, $x);
reason(<<"binary">>) ->
    binary:copy(<<$x>>, 8 * 1024 * 1024);
reason(<<"unicode">>) ->
    lists:duplicate(200000, 16#00E5);
reason(<<"nested">>) ->
    {outer, #{reason => [lists:duplicate(2000000, $x)]}};
reason(<<"combining">>) ->
    [$a | lists:duplicate(200000, 16#0301)];
reason(<<"emoji">>) ->
    lists:duplicate(200000, 16#1f680);
reason(_) ->
    boom.
