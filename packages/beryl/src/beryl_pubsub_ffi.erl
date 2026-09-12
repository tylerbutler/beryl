-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, join_group/4, leave_group/4,
         get_members/3, get_local_members/3, send_to_pid/3,
         scoped_to_message/1]).

start_pg_scope(Scope) ->
    case beryl_pubsub_supervisor:start_scope(Scope) of
        {ok, Registry} ->
            case gen_server:call(Registry, ready) of
                ok -> Registry;
                {error, Reason} -> exit({pubsub_start_failed, Scope, Reason})
            end;
        {error, Reason} -> exit({pubsub_start_failed, Scope, Reason})
    end.

join_group(Scope, Registry, Group, Pid) ->
    membership_call(Scope, Registry, {join, Group, Pid}).

leave_group(Scope, Registry, Group, Pid) ->
    membership_call(Scope, Registry, {leave, Group, Pid}).

membership_call(Scope, Registry, Request) ->
    case gen_server:call(Registry, Request) of
        ok -> nil;
        {error, Reason} -> exit({pubsub_unavailable, Scope, Reason})
    end.

get_members(Scope, Registry, Group) ->
    ensure_owner(Scope, Registry),
    pg:get_members(Scope, Group).
get_local_members(Scope, Registry, Group) ->
    ensure_owner(Scope, Registry),
    pg:get_local_members(Scope, Group).

ensure_owner(Scope, Registry) ->
    case is_process_alive(Registry) of
        true -> ok;
        false -> exit({pubsub_unavailable, Scope, owner_down})
    end.
send_to_pid(Pid, Scope, {message, Topic, Event, Payload, From}) ->
    Pid ! {Scope, Topic, Event, Payload, From}, nil.

scoped_to_message({_Scope, Topic, Event, Payload, From}) ->
    {message, Topic, Event, Payload, From}.
