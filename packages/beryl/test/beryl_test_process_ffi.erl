-module(beryl_test_process_ffi).
-export([mailbox_length/1, queue_memory_evidence/0, with_suspended/2,
         queue_call_lifecycle/0, publication_cleanup_races/0,
         stale_lifecycle_signals/3]).

stale_lifecycle_signals(Router, SocketId, OldActor) ->
    {registered_name, Name} = process_info(Router, registered_name),
    Router ! {Name, {index_join, SocketId, OldActor, <<"room:ghost">>}},
    Router ! {Name, {index_leave, SocketId, OldActor, <<"room:a">>}},
    Router ! {Name, {socket_closed, SocketId, OldActor}},
    Parent = self(),
    Tag = make_ref(),
    Router ! {Name, {get_stats, fun(Stats) -> Parent ! {Tag, Stats}, nil end}},
    receive
        {Tag, {stats_snapshot, 1, 1, 1}} -> nil;
        {Tag, Other} -> error({stale_lifecycle_changed_replacement, Other})
    after 1000 -> error(stale_lifecycle_barrier_timeout)
    end.

with_suspended(Pid, Action) ->
    true = erlang:suspend_process(Pid),
    try Action()
    after erlang:resume_process(Pid)
    end.

queue_call_lifecycle() ->
    Queue = beryl_work_queue_ffi:new(1, 128, router_queue, false, fun() -> nil end),
    {ok, Reservation} = beryl_work_queue_ffi:retain(Queue, nil),
    ok = case beryl_work_queue_ffi:attach_cleanup(Queue, Reservation,
        fun() -> self() ! provisional_cleaned, nil end) of {ok, nil} -> ok end,
    {error, request_timed_out} = beryl_work_queue_ffi:call_reserved(
        Queue, Reservation, 0, fun(Reply) -> Reply end),
    receive provisional_cleaned -> ok after 0 -> error(missing_cleanup) end,
    {ok, {occupancy, router_queue, 0, 0, _, _, _, _, _, 1, _}} =
        beryl_work_queue_ffi:snapshot(Queue),
    Parent = self(),
    Owner = spawn_link(fun() ->
        OwnerPid = self(),
        Target = beryl_work_queue_ffi:new(1, 128, router_queue, false,
            fun() -> OwnerPid ! consume, nil end),
        Parent ! {call_target, Target},
        receive consume -> ok end,
        {ok, {Id, Reply}} = beryl_work_queue_ffi:take(Target),
        Parent ! call_running,
        receive finish -> ok end,
        Reply(queue_late_reply),
        Reply(queue_late_reply),
        beryl_work_queue_ffi:release(Target, Id),
        Parent ! call_finished,
        receive stop -> ok end
    end),
    receive {call_target, Target} ->
        try
            {error, request_timed_out} = beryl_work_queue_ffi:call(
                Target, 100, fun(Reply) -> Reply end),
            receive call_running -> ok after 1000 -> error(call_not_running) end,
            {ok, {occupancy, router_queue, 1, _, _, _, _, _, _, 0, _}} =
                beryl_work_queue_ffi:snapshot(Target),
            Owner ! finish,
            receive call_finished -> ok after 1000 -> error(call_not_finished) end,
            {ok, {occupancy, router_queue, 0, 0, _, _, _, _, _, 0, _}} =
                beryl_work_queue_ffi:snapshot(Target),
            receive {Tag, queue_late_reply} when is_reference(Tag) ->
                error(late_alias_reply)
            after 0 -> nil end
        after
            unlink(Owner),
            exit(Owner, kill)
        end
    end.

publication_cleanup_races() ->
    Queue = beryl_work_queue_ffi:new(1, 128, socket_queue, false, fun() -> nil end),
    Parent = self(),
    lists:foreach(fun(_) ->
        Tag = make_ref(),
        {ok, Id} = beryl_work_queue_ffi:retain(Queue, nil),
        spawn(fun() -> Parent ! {Tag, published,
            beryl_work_queue_ffi:publish_reserved(Queue, Id, <<"report">>)} end),
        spawn(fun() ->
            beryl_work_queue_ffi:release_producer(Queue, Parent),
            Parent ! {Tag, released}
        end),
        receive {Tag, released} -> ok end,
        receive
            {Tag, published, {ok, Id}} ->
                {ok, {Id, <<"report">>}} = beryl_work_queue_ffi:take(Queue),
                beryl_work_queue_ffi:release(Queue, Id);
            {Tag, published, {error, closed}} -> ok
        end,
        {ok, {occupancy, socket_queue, 0, 0, _, _, _, _, _, _, _}} =
            beryl_work_queue_ffi:snapshot(Queue)
    end, lists:seq(1, 100)),
    nil.

mailbox_length(Pid) ->
    case erlang:process_info(Pid, message_queue_len) of
        {message_queue_len, Length} -> Length;
        undefined -> 0
    end.

queue_memory_evidence() ->
    Items = 8,
    PayloadBytes = 4096,
    Queue = beryl_work_queue_ffi:new(Items, Items * PayloadBytes, worker_queue,
        false, fun() -> self() ! queue_memory_wake, nil end),
    Empty = queue_diagnostics(Queue),
    %% Fixed fixture envelope: 128 words per lease covers its map entries,
    %% queue cells, references and binary headers, plus the source payloads.
    StorageLimit = maps:get(storage_words, Empty) + 128 * Items,
    ProcessLimit = maps:get(process_bytes, Empty) +
        Items * (PayloadBytes + 128 * erlang:system_info(wordsize)),
    Reservations = [begin
        {ok, Id} = beryl_work_queue_ffi:publish_value(
            Queue, binary:copy(<<Index>>, PayloadBytes)),
        Id
    end || Index <- lists:seq(1, Items)],
    Full = queue_diagnostics(Queue),
    true = maps:get(storage_words, Full) =< StorageLimit,
    Samples = lists:map(fun(Attempts) ->
        reject_attempts(Queue, binary:copy(<<0>>, PayloadBytes), Attempts),
        {ok, {occupancy, worker_queue, Items, Bytes, Items, Bytes,
              Items, Bytes, Rejected, 0, _Age}} = beryl_work_queue_ffi:snapshot(Queue),
        Bytes = Items * PayloadBytes,
        Sample = queue_diagnostics(Queue),
        true = maps:get(storage_words, Sample) =:= maps:get(storage_words, Full),
        true = maps:get(queued_binary_bytes, Sample) =:= Bytes,
        true = maps:get(mailbox_length, Sample) =< maps:get(mailbox_length, Empty) + 1,
        true = maps:get(process_bytes, Sample) =< ProcessLimit,
        Sample#{rejected => Rejected, items => Items, accounted_bytes => Bytes}
    end, [10, 1000, 10000]),
    lists:foreach(fun(Id) -> beryl_work_queue_ffi:release(Queue, Id) end, Reservations),
    receive queue_memory_wake -> ok after 0 -> error(missing_queue_wake) end,
    {ok, {occupancy, worker_queue, 0, 0, Items, _, Items, _, _, Items, _}} =
        beryl_work_queue_ffi:snapshot(Queue),
    Drained = queue_diagnostics(Queue),
    true = maps:get(storage_words, Drained) =:= maps:get(storage_words, Empty),
    0 = maps:get(queued_binary_bytes, Drained),
    iolist_to_binary(json:encode(#{
        runtime => list_to_binary(erlang:system_info(system_version)),
        word_bytes => erlang:system_info(wordsize),
        fixture_items => Items, payload_bytes => PayloadBytes,
        storage_limit_words => StorageLimit, process_limit_bytes => ProcessLimit,
        empty => Empty, full => Full, samples => Samples, cancelled => Drained
    })).

reject_attempts(_, _, 0) -> ok;
reject_attempts(Queue, Payload, Count) ->
    {error, {overloaded, worker_queue}} =
        beryl_work_queue_ffi:publish_value(Queue, Payload),
    reject_attempts(Queue, Payload, Count - 1).

queue_diagnostics({Table, Owner, _, _, _, _, _}) when Owner =:= self() ->
    true = erlang:garbage_collect(),
    {memory, Memory} = erlang:process_info(Owner, memory),
    {binary, Binaries} = erlang:process_info(Owner, binary),
    [{state, #{leases := Leases}}] = ets:lookup(Table, state),
    %% This fixture has only top-level binary publications.
    QueuedBytes = lists:sum([binary:referenced_byte_size(Payload) ||
        {pending, _, _, Payload} <- maps:values(Leases)]),
    #{storage_words => ets:info(Table, memory),
      process_bytes => Memory,
      mailbox_length => mailbox_length(Owner),
      process_binary_bytes => lists:sum([Size || {_, Size, _} <- Binaries]),
      queued_binary_bytes => QueuedBytes}.
