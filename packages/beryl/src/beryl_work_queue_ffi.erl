-module(beryl_work_queue_ffi).
-export([new/5, name/2, lookup/1, publish/3, publish_value/2, take/1, take_matching/2, release/2,
         retain/2, retain_output/2, resize/3, publish_reserved/3, validate/3, release_producer/2, call/3,
         attach_cleanup/3, recover/1, call_reserved/4,
         is_open/1, close_with_error/2, close_reason/1,
         register_target/3, remove_target/2, close_target/2,
         publish_with_cleanup/4, activate_cleanup/2,
         close/1, close_once/1, snapshot/1]).

new(MaxItems, MaxBytes, Boundary, Telemetry, Wake)
        when MaxItems > 0, MaxBytes > 0 ->
    Table = ets:new(?MODULE, [set, public, {read_concurrency, true}]),
    State = #{open => true, close_reason => none, version => 0, items => 0, bytes => 0,
              high_items => 0, high_bytes => 0, rejected => 0, cancelled => 0,
              pending => queue:new(),
              leases => #{}, cleanups => #{}, notified => false},
    true = ets:insert(Table, {state, State}),
    {Table, self(), MaxItems, MaxBytes, Boundary, Telemetry, Wake}.

name(Queue, Name) ->
    %% This table shares its owner's lifetime, not its registered process name.
    Index = case ets:info(Name, owner) of
        undefined -> ets:new(Name, [named_table, protected, set]);
        Owner when Owner =:= self() -> Name;
        _ -> erlang:error(queue_name_owned_by_another_process)
    end,
    true = ets:insert(Index, {queue, Queue}),
    nil.

lookup(Name) ->
    case safe_lookup(Name, queue) of
        [{queue, Queue}] -> {ok, Queue};
        [] -> {error, unavailable}
    end.

is_open({Table, _, _, _, _, _, _}) ->
    case safe_lookup(Table, state) of
        [{state, #{open := Open}}] -> Open;
        [] -> false
    end.

close_reason({Table, _, _, _, _, _, _}) ->
    case safe_lookup(Table, state) of
        [{state, State}] -> maps:get(close_reason, State);
        [] -> none
    end.

close_with_error(Queue, Error) ->
    case update(Queue, fun(State) ->
        case maps:get(open, State) of
            false -> {return, false};
            true -> {replace, State#{open := false, close_reason := {some, Error}}, true}
        end
    end) of
        {error, unavailable} -> false;
        Changed -> Changed
    end.

register_target({Table, Owner, _, _, _, _, _}, Key, Target) when Owner =:= self() ->
    true = ets:insert(Table, {{target, Key}, Target}),
    nil.

remove_target({Table, Owner, _, _, _, _, _}, Key) when Owner =:= self() ->
    true = ets:delete(Table, {target, Key}),
    nil.

close_target({Table, _, _, _, _, _, _}, Key) ->
    case safe_lookup(Table, {target, Key}) of
        [] -> nil;
        [{_, Target = {_, _, _, _, _, _, Wake}}] ->
            case close_once(Target) of true -> Wake(); false -> nil end
    end.

call(Queue, Timeout, Request) ->
    bounded_call(Queue, Timeout, Request, fun(Message) -> publish_value(Queue, Message) end).

call_reserved(Queue, Reservation, Timeout, Request) ->
    bounded_call(Queue, Timeout, Request,
                 fun(Message) -> publish_reserved(Queue, Reservation, Message) end).

bounded_call(Queue = {_, Owner, _, _, _, _, _}, Timeout, Request, Publish) ->
    Alias = erlang:alias([reply]),
    Tag = make_ref(),
    Reply = fun(Value) -> Alias ! {Tag, Value}, nil end,
    try
        case Publish(Request(Reply)) of
            {error, Error} -> {error, {admission_rejected, Error}};
            {ok, Id} ->
                Monitor = erlang:monitor(process, Owner),
                try
                    receive
                        {Tag, Value} -> {ok, Value};
                        {'DOWN', Monitor, process, Owner, _} -> {error, owner_unavailable}
                    after max(0, Timeout) ->
                        cancel_pending(Queue, Id),
                        {error, request_timed_out}
                    end
                after
                    erlang:demonitor(Monitor, [flush])
                end
        end
    after
        erlang:unalias(Alias),
        receive {Tag, _} -> ok after 0 -> ok end
    end.

cancel_pending(Queue, Id) ->
    update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Id, Leases) of
            {ok, {pending, Bytes, _, _}} ->
                Cleanups = maps:get(cleanups, State),
                Result = cleanup_result(maps:get(Id, Cleanups, none)),
                {replace, State#{
                    cancelled := maps:get(cancelled, State) + 1,
                    items := maps:get(items, State) - 1,
                    bytes := maps:get(bytes, State) - Bytes,
                    pending := queue:filter(fun(Item) -> Item =/= Id end,
                                            maps:get(pending, State)),
                    leases := maps:remove(Id, Leases),
                    cleanups := maps:remove(Id, Cleanups)}, Result};
            _ -> {return, nil}
        end
    end).

publish_value(Queue = {_, _, _, MaxBytes, _, _, _}, Message) ->
    publish(Queue, Message, payload_bytes([Message], 0, MaxBytes)).

validate(Value, Limit, Boundary) ->
    case payload_bytes([Value], 0, Limit) =< Limit of
        true -> {ok, nil};
        false -> {error, {item_too_large, Boundary}}
    end.

publish_with_cleanup(Queue = {_, _, MaxItems, MaxBytes, Boundary, _, _},
                     Key, Message, Cleanup) ->
    Bytes = payload_bytes([Message], 0, MaxBytes),
    CleanupBytes = payload_bytes([Cleanup], 0, MaxBytes),
    Id = make_ref(),
    CleanupId = make_ref(),
    Now = erlang:monotonic_time(millisecond),
    update(Queue, fun(State) ->
        #{open := Open, items := Items, bytes := Used, pending := Pending,
          leases := Leases, cleanups := Cleanups, notified := Notified} = State,
        {ExtraItems, ExtraBytes, NextCleanups, NextLeases, Closing} =
            case maps:find(Key, Cleanups) of
                error -> {1, CleanupBytes, Cleanups#{Key => CleanupId},
                    Leases#{CleanupId => {cleanup, CleanupBytes, Now, Cleanup}}, false};
                {ok, Existing} -> {0, 0, Cleanups, Leases,
                    element(1, maps:get(Existing, Leases)) =/= cleanup}
            end,
        Count = Items + 1 + ExtraItems,
        TotalBytes = Used + Bytes + ExtraBytes,
        case {Open andalso not Closing, Bytes + ExtraBytes =< MaxBytes,
              Count =< MaxItems andalso TotalBytes =< MaxBytes} of
            {false, _, _} -> {return, {error, closed}};
            {true, false, _} -> {return, {error, {item_too_large, Boundary}}};
            {true, true, false} -> {return, {error, {overloaded, Boundary}}};
            {true, true, true} ->
                {replace, State#{items := Count, bytes := TotalBytes,
                    high_items := max(Count, maps:get(high_items, State)),
                    high_bytes := max(TotalBytes, maps:get(high_bytes, State)),
                    pending := queue:in(Id, Pending), cleanups := NextCleanups,
                    leases := NextLeases#{Id => {pending, Bytes, Now, Message}},
                    notified := true}, {published, Id, not Notified}}
        end
    end).

activate_cleanup(Queue, Key) ->
    Result = update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Key, maps:get(cleanups, State)) of
            error -> {return, {ok, nil}};
            {ok, Id} ->
                case maps:get(Id, Leases) of
                    {cleanup, Bytes, _, Message} ->
                        Entry = {pending, Bytes, erlang:monotonic_time(millisecond), Message},
                        {replace, State#{
                            leases := Leases#{Id := Entry},
                            pending := queue:in(Id, maps:get(pending, State)),
                            notified := true},
                            {published, Id, not maps:get(notified, State)}};
                    _ -> {return, {ok, nil}}
                end
        end
    end),
    case Result of {ok, _} -> {ok, nil}; Error -> Error end.

retain(Queue, Value) -> retain(Queue, Value, false).
retain_output(Queue, Value) -> retain(Queue, Value, true).

retain(Queue = {_, _, MaxItems, MaxBytes, Boundary, _, _}, Value, Completing) ->
    Bytes = payload_bytes([Value], 0, MaxBytes),
    Id = make_ref(),
    At = erlang:monotonic_time(millisecond),
    Producer = self(),
    update(Queue, fun(State) ->
        #{open := Open, items := Items, bytes := Used, leases := Leases} = State,
        case {Open orelse Completing, Bytes =< MaxBytes, Items < MaxItems andalso Used + Bytes =< MaxBytes} of
            {false, _, _} -> {return, {error, closed}};
            {true, false, _} -> {return, {error, {item_too_large, Boundary}}};
            {true, true, false} -> {return, {error, {overloaded, Boundary}}};
            {true, true, true} ->
                Next = State#{items := Items + 1, bytes := Used + Bytes,
                    high_items := max(Items + 1, maps:get(high_items, State)),
                    high_bytes := max(Used + Bytes, maps:get(high_bytes, State)),
                    leases := Leases#{Id => {retained, Bytes, At, Producer, none}}},
                {replace, Next, {ok, Id}}
        end
    end).

resize(Queue = {_, _, _, MaxBytes, Boundary, _, _}, Id, Value) ->
    Bytes = payload_bytes([Value], 0, MaxBytes),
    update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Id, Leases) of
            error -> {return, {error, closed}};
            {ok, Entry} ->
                Used = maps:get(bytes, State) - element(2, Entry) + Bytes,
                case {Bytes =< MaxBytes, Used =< MaxBytes} of
                    {false, _} -> {return, {error, {item_too_large, Boundary}}};
                    {true, false} -> {return, {error, {overloaded, Boundary}}};
                    {true, true} ->
                        {replace, State#{bytes := Used,
                            high_bytes := max(Used, maps:get(high_bytes, State)),
                            leases := Leases#{Id := setelement(2, Entry, Bytes)}}, {ok, nil}}
                end
        end
    end).

publish_reserved(Queue = {_, _, _, MaxBytes, Boundary, _, _}, Id, Message) ->
    Bytes = payload_bytes([Message], 0, MaxBytes),
    update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Id, Leases) of
            {ok, {retained, Before, At, _, Cleanup}} ->
                Used = maps:get(bytes, State) - Before + Bytes,
                case {Bytes =< MaxBytes, Used =< MaxBytes} of
                    {false, _} -> {return, {error, {item_too_large, Boundary}}};
                    {true, false} -> {return, {error, {overloaded, Boundary}}};
                    {true, true} ->
                        {replace, State#{bytes := Used,
                            high_bytes := max(Used, maps:get(high_bytes, State)),
                            leases := Leases#{Id := {pending, Bytes, At, Message}},
                            cleanups := case Cleanup of
                                none -> maps:get(cleanups, State);
                                _ -> maps:put(Id, Cleanup, maps:get(cleanups, State))
                            end,
                            pending := queue:in(Id, maps:get(pending, State)),
                            notified := true},
                            {published, Id, not maps:get(notified, State)}}
                end;
            _ -> {return, {error, closed}}
        end
    end).

release_producer(Queue, Producer) ->
    release_retained(Queue, fun(Pid) -> Pid =:= Producer end).

attach_cleanup(Queue, Id, Cleanup) ->
    update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:find(Id, Leases) of
            {ok, {retained, Bytes, At, Producer, none}} ->
                {replace, State#{leases := Leases#{Id :=
                    {retained, Bytes, At, Producer, Cleanup}}}, {ok, nil}};
            _ -> {return, {error, closed}}
        end
    end).

recover(Queue = {_, Owner, _, _, _, _, _}) when Owner =:= self() ->
    release_retained(Queue, fun(Producer) -> not is_process_alive(Producer) end).

release_retained(Queue, ShouldRelease) ->
    Result = update(Queue, fun(State) ->
        {Leases, Items, Bytes, Cleanups} = maps:fold(fun
            (Id, {retained, Size, _, Producer, Cleanup}, {Keep, Count, Used, Actions}) ->
                case ShouldRelease(Producer) of
                    false -> {Keep, Count, Used, Actions};
                    true -> {maps:remove(Id, Keep), Count - 1, Used - Size,
                              [Cleanup | Actions]}
                end;
            (_, _, Acc) -> Acc
        end, {maps:get(leases, State), maps:get(items, State),
              maps:get(bytes, State), []}, maps:get(leases, State)),
        case Cleanups of
            [] -> {return, nil};
            _ -> {replace, State#{leases := Leases, items := Items, bytes := Bytes,
                                  cancelled := maps:get(cancelled, State) + length(Cleanups)},
                  {recovered, Cleanups}}
        end
    end),
    case Result of {error, unavailable} -> nil; nil -> nil end.

%% Structural accounting, not heap size. In particular, do not open an app's
%% sealed functions or traverse their captured model/typed-message environment.
payload_bytes(_, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_bytes([], Bytes, _) -> Bytes;
payload_bytes([Value | Rest], Bytes, Limit) when is_bitstring(Value) ->
    payload_bytes(Rest, Bytes + binary:referenced_byte_size(Value), Limit);
payload_bytes([[] | Rest], Bytes, Limit) ->
    payload_bytes(Rest, Bytes + 8, Limit);
payload_bytes([[Head | Tail] | Rest], Bytes, Limit) ->
    payload_bytes([Head, Tail | Rest], Bytes + 16, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_tuple(Value) ->
    payload_tuple(Value, 1, Rest, Bytes + 8, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_map(Value) ->
    payload_map(maps:iterator(Value), Rest, Bytes + 16, Limit);
payload_bytes([Value | Rest], Bytes, Limit) when is_integer(Value) ->
    payload_bytes(Rest, Bytes + max(8, erlang:external_size(Value)), Limit);
payload_bytes([_ | Rest], Bytes, Limit) ->
    payload_bytes(Rest, Bytes + 8, Limit).

payload_tuple(_, _, _, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_tuple(Value, Index, Rest, Bytes, Limit) when Index > tuple_size(Value) ->
    payload_bytes(Rest, Bytes, Limit);
payload_tuple(Value, Index, Rest, Bytes, Limit) ->
    Next = payload_bytes([element(Index, Value)], Bytes, Limit),
    payload_tuple(Value, Index + 1, Rest, Next, Limit).

payload_map(_, _, Bytes, Limit) when Bytes > Limit -> Bytes;
payload_map(Iterator, Rest, Bytes, Limit) ->
    case maps:next(Iterator) of
        none -> payload_bytes(Rest, Bytes, Limit);
        {Key, Value, Next} ->
            Used = payload_bytes([Key, Value], Bytes + 16, Limit),
            payload_map(Next, Rest, Used, Limit)
    end.

publish(Queue = {_, _, MaxItems, MaxBytes, Boundary, _, _}, Message, Bytes)
        when is_integer(Bytes), Bytes >= 0 ->
    case Bytes > MaxBytes of
        true -> update(Queue, fun(_) ->
            {return, {error, {item_too_large, Boundary}}}
        end);
        false ->
            Id = make_ref(),
            Now = erlang:monotonic_time(millisecond),
            update(Queue, fun(State) ->
                #{open := Open, items := Items, bytes := Used,
                  pending := Pending, leases := Leases,
                  notified := Notified} = State,
                case {Open, Items < MaxItems andalso Used + Bytes =< MaxBytes} of
                    {false, _} -> {return, {error, closed}};
                    {true, false} -> {return, {error, {overloaded, Boundary}}};
                    {true, true} ->
                        Entry = {pending, Bytes, Now, Message},
                        Next = State#{
                            items := Items + 1, bytes := Used + Bytes,
                            high_items := max(Items + 1, maps:get(high_items, State)),
                            high_bytes := max(Used + Bytes, maps:get(high_bytes, State)),
                            pending := queue:in(Id, Pending),
                            leases := Leases#{Id => Entry}, notified := true},
                        {replace, Next, {published, Id, not Notified}}
                end
            end)
    end.

take(Queue = {_, Owner, _, _, _, _, _}) when Owner =:= self() ->
    update(Queue, fun(State) ->
        case queue:out(maps:get(pending, State)) of
            {empty, _} ->
                {replace, State#{notified := false}, {error, nil}};
            {{value, Id}, Pending} ->
                Leases = maps:get(leases, State),
                {pending, Bytes, At, Message} = maps:get(Id, Leases),
                Next = State#{pending := Pending,
                              cleanups := maps:remove(Id, maps:get(cleanups, State)),
                              leases := Leases#{Id := {running, Bytes, At}}},
                {replace, Next, {ok, {Id, Message}}}
        end
    end).

take_matching(Queue = {_, Owner, _, _, _, _, _}, Eligible) when Owner =:= self() ->
    update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        Pending = maps:get(pending, State),
        case first_eligible(queue:to_list(Pending), Leases, Eligible) of
            none -> {replace, State#{notified := false}, {error, nil}};
            {Id, Bytes, At, Message} ->
                Next = State#{
                    cleanups := maps:remove(Id, maps:get(cleanups, State)),
                    pending := queue:filter(fun(Item) -> Item =/= Id end, Pending),
                    leases := Leases#{Id := {running, Bytes, At}}},
                {replace, Next, {ok, {Id, Message}}}
        end
    end).

first_eligible([], _, _) -> none;
first_eligible([Id | Rest], Leases, Eligible) ->
    {pending, Bytes, At, Message} = maps:get(Id, Leases),
    case Eligible(Message) of
        true -> {Id, Bytes, At, Message};
        false -> first_eligible(Rest, Leases, Eligible)
    end.

release(Queue, Id) ->
    case update(Queue, fun(State) ->
        Leases = maps:get(leases, State),
        case maps:take(Id, Leases) of
            error -> {return, nil};
            {Entry, Rest} ->
                Bytes = element(2, Entry),
                Cancelled = case element(1, Entry) of pending -> 1; _ -> 0 end,
                Result = case Entry of
                    {retained, _, _, _, Cleanup} -> cleanup_result(Cleanup);
                    _ -> cleanup_result(maps:get(Id, maps:get(cleanups, State), none))
                end,
                Pending = queue:filter(fun(Item) -> Item =/= Id end,
                                       maps:get(pending, State)),
                {replace, State#{items := maps:get(items, State) - 1,
                                 cancelled := maps:get(cancelled, State) + Cancelled,
                                 bytes := maps:get(bytes, State) - Bytes,
                                 pending := Pending, leases := Rest,
                                 cleanups := maps:filter(fun(Key, Value) -> Key =/= Id andalso Value =/= Id end,
                                                        maps:get(cleanups, State))}, Result}
        end
    end) of
        {error, unavailable} -> nil;
        nil -> nil
    end.

cleanup_result(none) -> nil;
cleanup_result(Cleanup) -> {released, Cleanup}.

close(Queue) ->
    case update(Queue, fun(State) ->
        {replace, State#{open := false}, nil}
    end) of
        {error, unavailable} -> nil;
        nil -> nil
    end.

close_once(Queue) ->
    case update(Queue, fun(State) ->
        case maps:get(open, State) of
            false -> {return, false};
            true -> {replace, State#{open := false}, true}
        end
    end) of
        {error, unavailable} -> false;
        Changed -> Changed
    end.

snapshot({Table, _, MaxItems, MaxBytes, Boundary, _, _}) ->
    case safe_lookup(Table, state) of
        [] -> {error, unavailable};
        [{state, State}] -> {ok, occupancy(State, MaxItems, MaxBytes, Boundary)}
    end.

%% ponytail: CAS copies a bounded ledger on each update. Replace with a
%% segmented ledger only if measured admission cost requires it.
update(Queue = {Table, _, _, _, _, _, _}, Change) ->
    case safe_lookup(Table, state) of
        [] -> {error, unavailable};
        [{state, Before}] ->
            case counted_change(Change(Before), Before) of
                {return, Result} ->
                    emit(Queue, Before, Result),
                    Result;
                {replace, Changed, Result} ->
                    After = Changed#{version := maps:get(version, Before) + 1},
                    Match = [{{state, '$1'},
                              [{'=:=', '$1', {const, Before}}],
                              [{const, {state, After}}]}],
                    case replace(Table, Match) of
                        unavailable -> {error, unavailable};
                        0 -> update(Queue, Change);
                        1 ->
                            finish(Queue, After, Result)
                    end
            end
    end.

counted_change({return, {error, {overloaded, _}}} = Result, State) ->
    count_rejection(Result, State);
counted_change({return, {error, {item_too_large, _}}} = Result, State) ->
    count_rejection(Result, State);
counted_change({return, {error, closed}} = Result, State) ->
    count_rejection(Result, State);
counted_change(Result, _) -> Result.

count_rejection({return, Result}, State) ->
    {replace, State#{rejected := maps:get(rejected, State) + 1}, Result}.

finish(Queue = {_, _, _, _, _, _, Wake}, State, {published, Id, Notify}) ->
    %% The payload is already durable in the owner-owned table. A producer
    %% killed here cannot strand capacity; the owner's recovery tick drains it.
    case Notify of true -> Wake(); false -> nil end,
    emit(Queue, State, admitted),
    {ok, Id};
finish(Queue, State, {released, Cleanup}) ->
    Cleanup(),
    emit(Queue, State, cancelled),
    nil;
finish(Queue, State, {recovered, Cleanups}) ->
    lists:foreach(fun(none) -> ok; (Cleanup) -> Cleanup() end, Cleanups),
    emit(Queue, State, cancelled),
    nil;
finish(Queue, State, Result) ->
    emit(Queue, State, Result),
    Result.

occupancy(State, MaxItems, MaxBytes, Boundary) ->
    Now = erlang:monotonic_time(millisecond),
    Oldest = maps:fold(fun
        (_, {cleanup, _, _, _}, At) -> At;
        (_, Entry, At) -> min(element(3, Entry), At)
    end, Now, maps:get(leases, State)),
    {occupancy, Boundary, maps:get(items, State), maps:get(bytes, State), MaxItems, MaxBytes,
     maps:get(high_items, State), maps:get(high_bytes, State),
     maps:get(rejected, State), maps:get(cancelled, State),
     max(0, Now - Oldest)}.

emit({_, _, _, _, _, false, _}, _, _) -> nil;
emit({_, _, MaxItems, MaxBytes, Boundary, true, _}, State, Result) ->
    Outcome = case Result of
        {error, {overloaded, _}} -> queue_rejected;
        {error, {item_too_large, _}} -> queue_rejected;
        {error, closed} -> queue_rejected;
        _ -> queue_changed
    end,
    beryl_telemetry_ffi:execute(
        {queue_occupancy, occupancy(State, MaxItems, MaxBytes, Boundary), Outcome}).

safe_lookup(Table, Key) ->
    try ets:lookup(Table, Key)
    catch error:badarg -> []
    end.

replace(Table, Match) ->
    try ets:select_replace(Table, Match)
    catch error:badarg ->
        %% A bad match specification must not masquerade as an owner exit.
        case ets:info(Table) of
            undefined -> unavailable;
            _ -> erlang:error(badarg)
        end
    end.
