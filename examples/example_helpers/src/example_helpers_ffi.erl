-module(example_helpers_ffi).
-export([string_to_codepoints/1]).

string_to_codepoints(Str) ->
    unicode:characters_to_list(Str).
