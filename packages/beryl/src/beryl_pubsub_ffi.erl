-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, join_group/3, leave_group/3,
         get_members/2, get_local_members/2, send_to_pid/3,
         scoped_to_message/1]).

start_pg_scope(Scope) -> _ = pg:start(Scope), nil.

join_group(Scope, Group, Pid) ->
    with_membership_lock(Scope, Group, Pid, fun() ->
        case lists:member(Pid, pg:get_local_members(Scope, Group)) of
            true -> nil;
            false -> ok = pg:join(Scope, Group, Pid), nil
        end
    end).

leave_group(Scope, Group, Pid) ->
    with_membership_lock(Scope, Group, Pid, fun() ->
        _ = pg:leave(Scope, Group, Pid), nil
    end).

with_membership_lock(Scope, Group, Pid, Operation) ->
    %% pg allows duplicate membership. Serialize the check and mutation across
    %% handles and callers; pg only accepts local member pids.
    global:trans({{?MODULE, Scope, Group, Pid}, self()}, Operation, [node()]).

get_members(Scope, Group) -> pg:get_members(Scope, Group).
get_local_members(Scope, Group) -> pg:get_local_members(Scope, Group).
send_to_pid(Pid, Scope, {message, Topic, Event, Payload, From}) ->
    Pid ! {Scope, Topic, Event, Payload, From}, nil.

scoped_to_message({_Scope, Topic, Event, Payload, From}) ->
    {message, Topic, Event, Payload, From}.
