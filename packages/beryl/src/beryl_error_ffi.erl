-module(beryl_error_ffi).
-export([describe_abnormal_exit/1, describe_operation_failure/1]).

%% Only called after matching process.Abnormal in Gleam. Keep the original
%% exit term in StartFailure and format it on demand, not through JSON.
%% Limit both nesting and output, including long flat binaries and lists.
describe_abnormal_exit({abnormal, Reason}) ->
    describe_operation_failure(Reason).

describe_operation_failure(Reason) ->
    Formatted = unicode:characters_to_binary(
        io_lib:format("~tP", [Reason, 10], [{chars_limit, 512}])),
    binary:copy(string:slice(Formatted, 0, 512)).
