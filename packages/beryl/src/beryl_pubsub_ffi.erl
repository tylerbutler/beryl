-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, start_memberships/1,
         registered_scope/1, is_local_pid/1,
         try_pg_join/3, try_pg_leave/3, try_pg_local_members/2,
         new_readiness/0, publish_readiness/2, clear_readiness/1,
         query_members/4, query_local_members/4,
         scoped_to_message/1, membership_actor_call/3,
         new_membership_intent/0, set_membership_intent/3, take_membership_intent/1]).

new_membership_intent() ->
    {ets:new(?MODULE, [set, protected]), self(), atomics:new(1, [])}.

set_membership_intent({Table, Owner, Notify}, Topic, Joined) when Owner =:= self() ->
    case Joined of
        true -> ets:insert(Table, {Topic});
        false -> ets:delete(Table, Topic)
    end,
    atomics:compare_exchange(Notify, 1, 0, 1) =:= ok.

take_membership_intent({Table, _Owner, Notify}) ->
    %% Clear before reading: an update during reconciliation queues one more wake.
    atomics:put(Notify, 1, 0),
    try {ok, [Topic || {Topic} <- ets:tab2list(Table)]}
    catch error:badarg -> {error, nil}
    end.

start_pg_scope(Scope) ->
    try beryl_pubsub_supervisor:start_scope(Scope) of
        {ok, RegistryPid} ->
            'beryl@pubsub_membership':from_pid(RegistryPid);
        {error, Reason} -> {error, Reason}
    catch
        %% Only OTP call exits are operational failures. Defects still raise.
        exit:{_, {gen_server, call, _}} = Reason -> {error, Reason}
    end.

start_memberships(Scope) ->
    case 'beryl@pubsub_membership':start(Scope) of
        {ok, {started, Pid, _Registry}} -> {ok, Pid};
        {error, Reason} -> {error, Reason}
    end.

%% A process alias drops late responses. The after block always removes the
%% callee monitor, including timeout and process-down paths.
membership_actor_call(Subject, Timeout, Request) ->
    beryl_ffi:actor_call(Subject, Timeout, Request).

registered_scope(Scope) ->
    case whereis(Scope) of
        undefined -> {error, nil};
        Pid -> {ok, Pid}
    end.

is_local_pid(Pid) ->
    is_pid(Pid) andalso node(Pid) =:= node().

try_pg_join(Scope, Group, Pid) ->
    try pg:join(Scope, Group, Pid), {ok, nil}
    catch
        exit:{_, {gen_server, call, _}} = Reason -> {error, {exit, Reason}};
        error:badarg -> {error, {error, badarg}}
    end.

try_pg_leave(Scope, Group, Pid) ->
    try pg:leave(Scope, Group, Pid), {ok, nil}
    catch
        exit:{_, {gen_server, call, _}} = Reason -> {error, {exit, Reason}};
        error:badarg -> {error, {error, badarg}}
    end.

try_pg_local_members(Scope, Group) ->
    pg_members(Scope, Group, fun pg:get_local_members/2).

%% Unnamed and protected: only the registry writes it, and handles retain the
%% actual table id across pg restarts. Registry death deletes it automatically.
%% pg itself uses the scope atom as a named ETS table, so do not reuse that name.
new_readiness() ->
    ets:new(?MODULE, [set, protected]).

publish_readiness(Table, PgPid) ->
    true = ets:insert(Table, {ready, PgPid}),
    nil.

clear_readiness(Table) ->
    true = ets:delete(Table, ready),
    nil.

query_members(Scope, Table, Registry, Group) ->
    query_members(Scope, Table, Registry, Group, fun pg:get_members/2).

query_local_members(Scope, Table, Registry, Group) ->
    query_members(Scope, Table, Registry, Group, fun pg:get_local_members/2).

query_members(Scope, Table, Registry, Group, Get) ->
    case ready_generation(Table, Registry) of
        {ok, PgPid} ->
            case whereis(Scope) of
                PgPid ->
                    try Get(Scope, Group) of
                        Members ->
                            checked_members(Scope, Table, Registry, PgPid, Members)
                    catch error:badarg ->
                        {error, {pg_unavailable, {error, badarg}}}
                    end;
                _ -> {error, scope_recovering}
            end;
        {error, Reason} -> {error, Reason}
    end.

checked_members(Scope, Table, Registry, PgPid, Members) ->
    %% Re-read the same table id, owner, and marker. Neither a new registry
    %% nor a new, not-yet-replayed pg process may turn this into an empty success.
    case ready_generation(Table, Registry) of
        {ok, PgPid} ->
            case whereis(Scope) of
                PgPid -> {ok, Members};
                _ -> {error, scope_recovering}
            end;
        {ok, _OtherGeneration} -> {error, scope_recovering};
        {error, Reason} -> {error, Reason}
    end.

ready_generation(Table, Registry) ->
    case is_process_alive(Registry) of
        false -> {error, registry_unavailable};
        true ->
            try
                case ets:info(Table, owner) of
                    Registry ->
                        case ets:lookup(Table, ready) of
                            [{ready, PgPid}] when is_pid(PgPid) -> {ok, PgPid};
                            _ -> {error, scope_recovering}
                        end;
                    undefined -> {error, scope_recovering};
                    _OtherOwner -> {error, registry_unavailable}
                end
            catch
                %% The original registry can die between the owner and marker
                %% reads. Only that table-lifetime race is a recoverable badarg.
                error:badarg ->
                    case is_process_alive(Registry) of
                        true -> {error, scope_recovering};
                        false -> {error, registry_unavailable}
                    end
            end
    end.

pg_members(Scope, Group, Get) ->
    %% pg itself returns [] when its table is absent. Do not mistake that
    %% recovery state for a successful empty topic. Check the generation too.
    case whereis(Scope) of
        undefined -> {error, {scope_unavailable, Scope}};
        Pid ->
            try Get(Scope, Group) of
                Members ->
                    case whereis(Scope) of
                        Pid -> {ok, Members};
                        _ -> {error, {scope_changed, Scope}}
                    end
            catch error:badarg -> {error, {error, badarg}}
            end
    end.

scoped_to_message({_Scope, Topic, Event, Payload, From}) ->
    {message, Topic, Event, Payload, From}.
