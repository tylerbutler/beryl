-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, join_group/3, leave_group/3,
         get_members/2, get_local_members/2, send_to_pid/2]).

start_pg_scope(Scope) -> pg:start(Scope).

join_group(Scope, Group, Pid) -> pg:join(Scope, Group, Pid).
leave_group(Scope, Group, Pid) -> pg:leave(Scope, Group, Pid).
get_members(Scope, Group) -> pg:get_members(Scope, Group).
get_local_members(Scope, Group) -> pg:get_local_members(Scope, Group).
send_to_pid(Pid, Msg) -> Pid ! Msg, nil.
