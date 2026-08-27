-module(showcase_ffi).
-export([timestamp_ms/0]).

%% Returns the current Unix timestamp in milliseconds
timestamp_ms() ->
    erlang:system_time(millisecond).
