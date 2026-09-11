-module(beryl_diagnostic_test_ffi).
-export([rescue_description/2, abnormal_exit_description/1,
         referenced_byte_size/1]).

rescue_description(<<"error">>, Shape) ->
    rescue(fun() -> erlang:error(reason(Shape)) end);
rescue_description(<<"exit">>, Shape) ->
    rescue(fun() -> erlang:exit(reason(Shape)) end);
rescue_description(<<"throw">>, Shape) ->
    rescue(fun() -> erlang:throw(reason(Shape)) end).

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
reason(<<"unicode">>) ->
    lists:duplicate(200000, 16#00E5);
reason(<<"nested">>) ->
    {outer, #{reason => [lists:duplicate(2000000, $x)]}}.
