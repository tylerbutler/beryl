-module(beryl_pubsub_supervisor).
-behaviour(supervisor).
-export([start_scope/1, start_link/1, init/1]).

start_scope(Scope) ->
    case start_root() of
        {ok, Root} ->
            Child = #{id => Scope, start => {?MODULE, start_link, [Scope]},
                      type => supervisor},
            case supervisor:start_child(Root, Child) of
                {ok, Supervisor} -> registry(Supervisor);
                {error, {already_started, Supervisor}} -> registry(Supervisor);
                {error, Reason} -> {error, Reason}
            end;
        {error, Reason} -> {error, Reason}
    end.

registry(Supervisor) ->
    case lists:keyfind(memberships, 1, supervisor:which_children(Supervisor)) of
        {memberships, Pid, worker, _} when is_pid(Pid) -> {ok, Pid};
        _ -> {error, scope_restarting}
    end.

start_root() ->
    %% The node service must not inherit the lifetime or links of its first caller.
    {Bootstrap, Monitor} = spawn_monitor(fun() ->
        Result = supervisor:start_link({local, ?MODULE}, ?MODULE, root),
        case Result of
            {ok, Pid} -> unlink(Pid);
            {error, _} -> ok
        end,
        exit({pubsub_started, Result})
    end),
    receive
        {'DOWN', Monitor, process, Bootstrap, {pubsub_started, {ok, Pid}}} ->
            {ok, Pid};
        {'DOWN', Monitor, process, Bootstrap,
         {pubsub_started, {error, {already_started, Pid}}}} ->
            {ok, Pid};
        {'DOWN', Monitor, process, Bootstrap, {pubsub_started, {error, Reason}}} ->
            {error, Reason};
        {'DOWN', Monitor, process, Bootstrap, Reason} ->
            {error, Reason}
    end.

start_link(Scope) -> supervisor:start_link(?MODULE, {scope, Scope}).

init(root) ->
    {ok, {#{strategy => one_for_one}, []}};
init({scope, Scope}) ->
    %% A pg-only restart preserves the authoritative membership set. A registry
    %% restart also replaces pg; old handles retain the dead registry pid.
    Children = [
        #{id => memberships, start => {beryl_pubsub_memberships, start_link, [Scope]}},
        #{id => pg, start => {pg, start_link, [Scope]}}
    ],
    {ok, {#{strategy => rest_for_one, intensity => 5, period => 10}, Children}}.
