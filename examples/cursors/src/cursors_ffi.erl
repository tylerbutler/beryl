-module(cursors_ffi).
-export([string_to_codepoints/1]).

string_to_codepoints(String) ->
    lists:map(fun(CP) -> CP end, unicode:characters_to_list(String)).
