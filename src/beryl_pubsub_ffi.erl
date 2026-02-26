-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, start_pg_scope_with_pid/1, join_group/3, leave_group/3,
         get_members/2, get_local_members/2, send_to_pid/2]).

start_pg_scope(Scope) -> pg:start(Scope).

%% Start pg scope and return just the pid (for supervisor integration)
start_pg_scope_with_pid(Scope) ->
    case pg:start(Scope) of
        {ok, Pid} -> {ok, Pid};
        {error, {already_started, Pid}} -> {ok, Pid};
        Other -> Other
    end.
join_group(Scope, Group, Pid) -> pg:join(Scope, Group, Pid).
leave_group(Scope, Group, Pid) -> pg:leave(Scope, Group, Pid).
get_members(Scope, Group) -> pg:get_members(Scope, Group).
get_local_members(Scope, Group) -> pg:get_local_members(Scope, Group).
send_to_pid(Pid, Msg) -> Pid ! Msg, nil.
