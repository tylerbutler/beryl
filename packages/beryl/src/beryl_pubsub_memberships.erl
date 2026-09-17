-module(beryl_pubsub_memberships).
-behaviour(gen_server).
-export([start_link/1, init/1, handle_call/3, handle_cast/2, handle_info/2]).

-record(state, {scope, owners = #{}, pg = undefined, retry = undefined}).

start_link(Scope) -> gen_server:start_link(?MODULE, Scope, []).

init(Scope) ->
    %% pg is the next supervisor child, so init must not wait for it.
    {ok, retry(#state{scope = Scope})}.

handle_call(ready, _From, State) ->
    {Reply, Next} = synchronise(State, fun() -> ok end),
    {reply, Reply, Next};
handle_call({join, Topic, Pid}, _From, State) when node(Pid) =:= node() ->
    Next = add_owner(State, Topic, Pid),
    {Reply, Synced} = synchronise(Next, fun() ->
        join_once(State#state.scope, Topic, Pid)
    end),
    {reply, Reply, Synced};
handle_call({leave, Topic, Pid}, _From, State) ->
    Next = remove_topic(State, Topic, Pid),
    {Reply, Synced} = synchronise(Next, fun() ->
        _ = pg:leave(State#state.scope, Topic, Pid),
        ok
    end),
    {reply, Reply, Synced}.

handle_cast(_Message, State) -> {noreply, State}.

handle_info(recover, State) ->
    {_Reply, Next} = synchronise(State#state{retry = undefined}, fun() -> ok end),
    {noreply, Next};
handle_info({'DOWN', Ref, process, Pid, _Reason},
            State = #state{pg = {Pid, Ref}}) ->
    {noreply, retry(State#state{pg = undefined})};
handle_info({'DOWN', Ref, process, Pid, _Reason}, State = #state{owners = Owners}) ->
    case maps:find(Pid, Owners) of
        {ok, {Ref, _Topics}} ->
            {noreply, State#state{owners = maps:remove(Pid, Owners)}};
        _ -> {noreply, State}
    end.

add_owner(State = #state{owners = Owners}, Topic, Pid) ->
    {Ref, Topics} = case maps:find(Pid, Owners) of
        {ok, Existing} -> Existing;
        error -> {monitor(process, Pid), #{}}
    end,
    State#state{owners = Owners#{Pid => {Ref, Topics#{Topic => true}}}}.

remove_topic(State = #state{owners = Owners}, Topic, Pid) ->
    case maps:find(Pid, Owners) of
        error -> State;
        {ok, {Ref, Topics}} ->
            Remaining = maps:remove(Topic, Topics),
            case map_size(Remaining) of
                0 ->
                    demonitor(Ref, [flush]),
                    State#state{owners = maps:remove(Pid, Owners)};
                _ -> State#state{owners = Owners#{Pid => {Ref, Remaining}}}
            end
    end.

synchronise(State = #state{scope = Scope}, Operation) ->
    try
        Pid = whereis(Scope),
        ok = recover(State, Pid),
        ok = Operation(),
        %% A replacement can itself fail during replay or mutation. Never mark
        %% a mixed generation ready; retry from the same authoritative set.
        case whereis(Scope) =:= Pid andalso is_process_alive(Pid) of
            true -> {ok, watch_pg(State, Pid)};
            false -> throw(scope_recovering)
        end
    catch
        throw:scope_recovering ->
            {{error, scope_recovering}, retry(forget_pg(State))};
        exit:{Reason, {gen_server, call, [Scope | _]}} ->
            {{error, {pg_unavailable, Reason}}, retry(forget_pg(State))}
    end.

recover(_State, undefined) -> throw(scope_recovering);
recover(#state{pg = {Pid, _Ref}}, Pid) -> ok;
recover(#state{scope = Scope, owners = Owners}, _Pid) ->
    maps:foreach(fun(Owner, {_Monitor, Topics}) ->
        case is_process_alive(Owner) of
            true ->
                maps:foreach(fun(Topic, true) -> join_once(Scope, Topic, Owner) end, Topics);
            false -> ok
        end
    end, Owners).

watch_pg(State = #state{pg = {Pid, _Ref}}, Pid) -> State;
watch_pg(State, Pid) ->
    Next = forget_pg(State),
    Next#state{pg = {Pid, monitor(process, Pid)}}.

join_once(Scope, Topic, Pid) ->
    case lists:member(Pid, pg:get_local_members(Scope, Topic)) of
        true -> ok;
        false -> pg:join(Scope, Topic, Pid)
    end.

forget_pg(State = #state{pg = undefined}) -> State;
forget_pg(State = #state{pg = {_Pid, Ref}}) ->
    demonitor(Ref, [flush]),
    State#state{pg = undefined}.

retry(State = #state{retry = undefined}) ->
    State#state{retry = erlang:send_after(10, self(), recover)};
retry(State) -> State.
