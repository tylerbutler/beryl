-module(heirloom_ffi).
-export([marker/0]).

-spec marker() -> binary().
marker() ->
    <<"consumer heirloom">>.
