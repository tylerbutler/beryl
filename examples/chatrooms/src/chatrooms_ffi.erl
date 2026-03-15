-module(chatrooms_ffi).
-export([timestamp_ms/0, string_to_codepoints/1]).

%% Returns the current Unix timestamp in milliseconds
timestamp_ms() ->
    erlang:system_time(millisecond).

%% Convert a string to a list of codepoint integers
string_to_codepoints(Str) ->
    unicode:characters_to_list(Str).
