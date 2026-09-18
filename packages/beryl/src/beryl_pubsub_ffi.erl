-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, start_memberships/1,
         join_group/4, leave_group/4,
         get_members/3, get_local_members/3,
         registered_scope/1, is_local_pid/1,
         try_pg_join/3, try_pg_leave/3, try_pg_local_members/2,
         scoped_to_message/1]).

start_pg_scope(Scope) ->
    case beryl_pubsub_supervisor:start_scope(Scope) of
        {ok, RegistryPid} ->
            Registry = 'beryl@pubsub_memberships':from_pid(RegistryPid),
            case membership_call(fun() ->
                'beryl@pubsub_memberships':ready(Registry)
            end) of
                ok -> Registry;
                {error, Reason} -> exit({pubsub_start_failed, Scope, Reason})
            end;
        {error, Reason} -> exit({pubsub_start_failed, Scope, Reason})
    end.

start_memberships(Scope) ->
    case 'beryl@pubsub_memberships':start(Scope) of
        {ok, {started, Pid, _Registry}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

join_group(Scope, Registry, Group, Pid) ->
    membership_call(Scope, fun() ->
        'beryl@pubsub_memberships':join(Registry, Group, Pid)
    end).

leave_group(Scope, Registry, Group, Pid) ->
    membership_call(Scope, fun() ->
        'beryl@pubsub_memberships':leave(Registry, Group, Pid)
    end).

membership_call(Scope, Operation) ->
    case membership_call(Operation) of
        ok -> nil;
        {error, Reason} -> exit({pubsub_unavailable, Scope, Reason})
    end.

membership_call(Operation) ->
    try Operation() of
        {ok, nil} -> ok;
        {error, Reason} -> {error, Reason}
    catch
        Class:Reason -> {error, {actor_call_failed, Class, Reason}}
    end.

get_members(Scope, Registry, Group) ->
    ensure_owner(Scope, Registry),
    'beryl@pubsub_native':get_members(Scope, Group).
get_local_members(Scope, Registry, Group) ->
    ensure_owner(Scope, Registry),
    'beryl@pubsub_native':get_local_members(Scope, Group).

ensure_owner(Scope, Registry) ->
    case 'beryl@pubsub_memberships':is_alive(Registry) of
        true -> ok;
        false -> exit({pubsub_unavailable, Scope, owner_down})
    end.

registered_scope(Scope) ->
    case whereis(Scope) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

is_local_pid(Pid) ->
    is_pid(Pid) andalso node(Pid) =:= node().

try_pg_join(Scope, Group, Pid) ->
    try pg:join(Scope, Group, Pid), {ok, nil}
    catch Class:Reason -> {error, {Class, Reason}}
    end.

try_pg_leave(Scope, Group, Pid) ->
    try pg:leave(Scope, Group, Pid), {ok, nil}
    catch Class:Reason -> {error, {Class, Reason}}
    end.

try_pg_local_members(Scope, Group) ->
    try {ok, pg:get_local_members(Scope, Group)}
    catch Class:Reason -> {error, {Class, Reason}}
    end.

scoped_to_message({_Scope, Topic, Event, Payload, From}) ->
    {message, Topic, Event, Payload, From}.
