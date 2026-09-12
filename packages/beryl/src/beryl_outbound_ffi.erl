-module(beryl_outbound_ffi).
-export([new/0, reserve_and_send/6, release/2, close_and_send/2, cancel/1]).

%% One CAS updates both budgets: 23 frame bits above 40 payload-byte bits.
%% A negative value permanently closes admission; no process owns a lock.
new() ->
    Budget = atomics:new(1, [{signed, true}]),
    atomics:put(Budget, 1, 0),
    Budget.

reserve_and_send(Budget, Subject, Message, Bytes, MaxFrames, MaxBytes) ->
    reserve_and_send(
        Budget, Subject, Message, Bytes, MaxFrames, MaxBytes,
        atomics:get(Budget, 1)).

release(Budget, Bytes) ->
    release(Budget, Bytes, atomics:get(Budget, 1)).

close_and_send(Budget, Subject) ->
    close_and_send(Budget, Subject, atomics:get(Budget, 1)).

cancel(Budget) ->
    atomics:put(Budget, 1, -1),
    nil.

reserve_and_send(_Budget, _Subject, _Message, _Bytes, _MaxFrames, _MaxBytes,
                 State) when State < 0 ->
    false;
reserve_and_send(Budget, Subject, Message, Bytes, MaxFrames, MaxBytes, State) ->
    Frames = State div (1 bsl 40),
    ReservedBytes = State rem (1 bsl 40),
    case Frames + 1 =< MaxFrames
         andalso ReservedBytes + Bytes =< MaxBytes of
        false ->
            close(Budget, State),
            false;
        true ->
            NewState = State + (1 bsl 40) + Bytes,
            case atomics:compare_exchange(Budget, 1, State, NewState) of
                ok ->
                    send_subject(Subject, Message),
                    true;
                Actual ->
                    reserve_and_send(
                        Budget, Subject, Message, Bytes, MaxFrames, MaxBytes,
                        Actual)
            end
    end.

release(_Budget, _Bytes, State) when State < 0 ->
    nil;
release(Budget, Bytes, State) ->
    NewState = max(State - (1 bsl 40) - Bytes, 0),
    case atomics:compare_exchange(Budget, 1, State, NewState) of
        ok -> nil;
        Actual -> release(Budget, Bytes, Actual)
    end.

close_and_send(_Budget, _Subject, State) when State < 0 ->
    nil;
close_and_send(Budget, Subject, State) ->
    case atomics:compare_exchange(Budget, 1, State, -1) of
        ok -> send_subject(Subject, close);
        Actual -> close_and_send(Budget, Subject, Actual)
    end.

close(_Budget, State) when State < 0 ->
    nil;
close(Budget, State) ->
    case atomics:compare_exchange(Budget, 1, State, -1) of
        ok -> nil;
        Actual -> close(Budget, Actual)
    end.

send_subject({subject, Pid, Tag}, Message) ->
    Pid ! {Tag, Message},
    nil.
