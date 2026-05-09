-module(collab_docs_ffi).

-export([timestamp_ms/0, random_id/0]).

timestamp_ms() ->
    erlang:system_time(millisecond).

random_id() ->
    integer_to_binary(erlang:unique_integer([positive, monotonic]), 36).
