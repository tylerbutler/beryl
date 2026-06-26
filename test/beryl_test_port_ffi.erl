-module(beryl_test_port_ffi).
-export([available_port/0]).

available_port() ->
    case gen_tcp:listen(0, [
        inet,
        {ip, {127, 0, 0, 1}},
        {active, false},
        {reuseaddr, false}
    ]) of
        {ok, Socket} ->
            Result = case inet:sockname(Socket) of
                {ok, {{127, 0, 0, 1}, Port}} -> {ok, Port};
                {ok, {_Address, Port}} -> {ok, Port};
                {error, _Reason} -> {error, nil}
            end,
            _ = gen_tcp:close(Socket),
            Result;
        {error, _Reason} ->
            {error, nil}
    end.
