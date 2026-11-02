-module(beryl_ffi).
-export([identity/1,
         logging_debug_enabled/0,
         string_starts_with/2, stop_supervisor/1, rescue/1,
         actor_call/3, connection_limit_call/3, connection_limit_send/2,
         connection_limit_checkpoint_supervisor/0,
         connection_limit_checkpoint_registry_key/2,
         connection_limit_checkpoint_registry_get/1,
         connection_limit_checkpoint_registry_put/2,
         connection_limit_checkpoint_registry_compare_erase/2,
         pin_subject/1]).

%% Used only after a selector validates the frozen raw PubSub record shape.
identity(X) -> X.

logging_debug_enabled() ->
    %% Palabres uses metadata-free logger:log/2, not a module-level macro.
    case logger:get_primary_config() of
        #{level := all} -> true;
        #{level := debug} -> true;
        _ -> false
    end.

%% Resolve once and retain the existing subject tag. Sending to this captured
%% pid after an exit is safe and cannot reach a replacement registered name.
pin_subject({named_subject, Name}) when is_atom(Name) ->
    case erlang:whereis(Name) of
        undefined -> {error, nil};
        Pid -> {ok, {{subject, Pid, Name}, Pid}}
    end;
pin_subject({subject, Pid, _Tag} = Subject) when is_pid(Pid) ->
    {ok, {Subject, Pid}}.

%% Run a callback, converting any crash (error/exit/throw) into an
%% {error, Description} result so a crashing callback cannot take down the
%% runtime actor running it. Reserve half the diagnostic for call sites, so a
%% large reason cannot hide them. Never pass stack arguments to the formatter.
rescue(Fun) ->
    try
        {ok, Fun()}
    catch
        Class:Reason:Stacktrace ->
            Description = diagnostic_format("~p:~tP", [Class, Reason, 10], 256),
            Frames = [stack_frame(Frame) ||
                      Frame <- lists:sublist(Stacktrace, 3)],
            Stack = diagnostic_format(" stack: ~ts",
                                      [lists:join(" <- ", Frames)], 256),
            {error, binary:copy(<<Description/binary, Stack/binary>>)}
    end.

%% Limit code points, not graphemes: a combining sequence can be arbitrarily
%% large. The copied result is valid UTF-8, <=512 code points / 2048 bytes.
diagnostic_format(Format, Arguments, Limit) ->
    Text = io_lib:format(Format, Arguments, [{chars_limit, Limit}]),
    unicode:characters_to_binary(
        lists:sublist(unicode:characters_to_list(Text), Limit)).

stack_frame({Module, Function, Arguments, Location})
        when is_atom(Module), is_atom(Function) ->
    Arity = stack_arity(Arguments, 0),
    ModuleName = diagnostic_format("~tp", [Module], 28),
    FunctionName = diagnostic_format("~tp", [Function], 28),
    Call = unicode:characters_to_list([ModuleName, ":", FunctionName, "/", Arity]),
    Source = stack_location(stack_location_entries(Location, 8), 80 - length(Call)),
    unicode:characters_to_binary([Call, Source]);
stack_frame({Function, Arguments, Location}) when is_function(Function) ->
    {module, Module} = erlang:fun_info(Function, module),
    {name, Name} = erlang:fun_info(Function, name),
    stack_frame({Module, Name, Arguments, Location});
stack_frame(_) ->
    <<"unknown">>.

stack_arity(Arity, 0) when is_integer(Arity), Arity >= 0, Arity =< 255 ->
    integer_to_list(Arity);
stack_arity([], Count) ->
    integer_to_list(Count);
stack_arity([_ | Rest], Count) when Count < 255 ->
    stack_arity(Rest, Count + 1);
stack_arity(_, _) ->
    "?".

%% erlang:raise/3 accepts improper location lists. Copy only the bounded
%% prefix so metadata traversal cannot throw while handling the exception.
stack_location_entries(_, 0) -> [];
stack_location_entries([Entry | Rest], Remaining) ->
    [Entry | stack_location_entries(Rest, Remaining - 1)];
stack_location_entries(_, _) -> [].

stack_location(Location, Budget) ->
    Line = case proplists:get_value(line, Location) of
        Number when is_integer(Number), Number >= 0, Number =< 16#7fffffff ->
            ":" ++ integer_to_list(Number);
        _ -> []
    end,
    File = case proplists:get_value(file, Location) of
        Path when is_list(Path) ->
            %% Compiler paths can be absolute. Bound even caller-supplied
            %% paths and replace invalid code points before formatting.
            Name = filename:basename(stack_path(Path, 1024)),
            Limit = Budget - length(Line),
            diagnostic_format(" ~ts", [lists:sublist(Name, Limit - 1)], Limit);
        _ -> <<>>
    end,
    [File, Line].

stack_path(_, 0) -> [];
stack_path([Character | Rest], Remaining)
        when is_integer(Character), Character >= 32, Character =< 16#10ffff,
             (Character < 16#d800 orelse Character > 16#dfff) ->
    [Character | stack_path(Rest, Remaining - 1)];
stack_path([_ | Rest], Remaining) ->
    [$? | stack_path(Rest, Remaining - 1)];
stack_path(_, _) -> [].

%% Deactivating the reply alias drops responses that arrive after this call
%% returns, while the monitor reports limiter death without waiting for timeout.
connection_limit_call(Subject, Timeout, Request) ->
    case connection_limit_subject_owner(Subject) of
        undefined ->
            {error, call_owner_unavailable};
        Owner ->
            Alias = erlang:alias([reply]),
            Tag = make_ref(),
            Reply = {subject, Alias, Tag},
            Monitor = erlang:monitor(process, Owner),
            try
                Owner ! connection_limit_subject_message(
                    Subject, Request(Reply)),
                receive
                    {Tag, Value} -> {ok, Value};
                    {'DOWN', Monitor, process, Owner, _Reason} ->
                        {error, call_owner_unavailable}
                after max(0, Timeout) ->
                    {error, call_timed_out}
                end
            after
                erlang:demonitor(Monitor, [flush]),
                erlang:unalias(Alias),
                receive {Tag, _} -> ok after 0 -> ok end
            end
    end.

actor_call(Subject, Timeout, Request) ->
    case connection_limit_subject_owner(Subject) of
        undefined ->
            {error, call_unavailable};
        Owner ->
            Alias = erlang:alias([reply]),
            Tag = make_ref(),
            Reply = {subject, Alias, Tag},
            Monitor = erlang:monitor(process, Owner),
            try
                Owner ! connection_limit_subject_message(Subject, Request(Reply)),
                receive
                    {Tag, Value} -> {ok, Value};
                    {'DOWN', Monitor, process, Owner, Reason} ->
                        {error, {call_down, gleam_erlang_ffi:cast_exit_reason(Reason)}}
                after max(0, Timeout) ->
                    {error, call_timed_out}
                end
            after
                erlang:demonitor(Monitor, [flush]),
                erlang:unalias(Alias),
                receive {Tag, _} -> ok after 0 -> ok end
            end
    end.

connection_limit_send(Subject, Message) ->
    case connection_limit_subject_owner(Subject) of
        undefined -> false;
        Owner ->
            Owner ! connection_limit_subject_message(Subject, Message),
            true
    end.

connection_limit_subject_owner({subject, Owner, _Tag}) ->
    case is_process_alive(Owner) of
        true -> Owner;
        false -> undefined
    end;
connection_limit_subject_owner({named_subject, Name}) ->
    whereis(Name).

connection_limit_subject_message({subject, _Owner, Tag}, Message) ->
    {Tag, Message};
connection_limit_subject_message({named_subject, Name}, Message) ->
    {Name, Message}.

connection_limit_checkpoint_supervisor() ->
    case erlang:get('$ancestors') of
        [Pid | _] when is_pid(Pid) -> Pid;
        _ -> erlang:error(connection_limit_supervisor_missing)
    end.

connection_limit_checkpoint_registry_key(Supervisor, Key) ->
    {?MODULE, connection_limit_state, Supervisor, Key}.

connection_limit_checkpoint_registry_get(PersistentKey) ->
    case persistent_term:get(PersistentKey, undefined) of
        undefined -> none;
        Table -> {some, Table}
    end.

connection_limit_checkpoint_registry_put(PersistentKey, Table) ->
    persistent_term:put(PersistentKey, Table),
    nil.

connection_limit_checkpoint_registry_compare_erase(PersistentKey, Table) ->
    case persistent_term:get(PersistentKey, undefined) of
        Table -> persistent_term:erase(PersistentKey);
        _ -> ok
    end,
    nil.

%% Check if a string starts with a prefix
string_starts_with(String, Prefix) ->
    PrefixLen = byte_size(Prefix),
    case String of
        <<Prefix:PrefixLen/binary, _/binary>> -> true;
        _ -> false
    end.

%% Stop a supervisor process cleanly.
%% Unlinks first so the calling process is not affected, then sends
%% a shutdown exit signal which the supervisor handles by terminating
%% all children before itself.
stop_supervisor(Pid) ->
    erlang:unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    erlang:exit(Pid, shutdown),
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> nil
    after
        5000 ->
            erlang:demonitor(MRef, [flush]),
            erlang:exit(Pid, kill),
            nil
    end.
