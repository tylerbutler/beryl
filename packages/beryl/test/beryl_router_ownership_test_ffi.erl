-module(beryl_router_ownership_test_ffi).
-export([with_cleanup/2, guardian/2, with_suspended/2, topic_factory/2]).

%% Exceptions remain test failures; cleanup must also run on assertion failure.
with_cleanup(Action, Cleanup) ->
    try Action() after Cleanup() end.

guardian(Router, Socket) ->
    {monitored_by, RouterWatchers} = process_info(Router, monitored_by),
    {monitored_by, SocketWatchers} = process_info(Socket, monitored_by),
    case [Pid || Pid <- RouterWatchers,
                 Pid =/= self(),
                 lists:member(Pid, SocketWatchers),
                 monitors_exactly(Pid, Router, Socket)] of
        [Pid] -> {ok, Pid};
        _ -> {error, nil}
    end.

monitors_exactly(Pid, Router, Socket) ->
    case process_info(Pid, monitors) of
        {monitors, Monitors} ->
            lists:sort(Monitors) =:=
                lists:sort([{process, Router}, {process, Socket}]);
        undefined -> false
    end.

%% The socket links only its parent socket factory and its topic factory.
topic_factory(Socket, SocketFactory) ->
    {links, Links} = process_info(Socket, links),
    case Links -- [SocketFactory] of
        [Pid] when is_pid(Pid) -> {ok, Pid};
        _ -> {error, nil}
    end.

with_suspended(Pid, Action) ->
    true = erlang:suspend_process(Pid),
    try Action()
    after
        case is_process_alive(Pid) of
            true -> erlang:resume_process(Pid);
            false -> ok
        end
    end.
