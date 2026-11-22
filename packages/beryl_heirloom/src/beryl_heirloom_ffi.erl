-module(beryl_heirloom_ffi).
-export([create/7, insert/3, lookup/2, delete/1, exists/1, owner/1, heir/1,
         set_heir/3, clear_heir/1, give_away/3, validate_transfer/1]).

-define(TRANSFER_TAG, beryl_heirloom_transfer).

-spec create(binary(), atom(), atom(), boolean(), boolean(), boolean(), term()) ->
    {ok, ets:tid()} | {error, atom()}.
create(Name, Type, Access, Named, ReadConcurrency, WriteConcurrency, Heir) ->
    case table_name(Name, Named) of
        {error, Error} ->
            {error, Error};
        {ok, AtomName} ->
            case heir_option(Heir) of
                {error, Error} ->
                    {error, Error};
                {ok, HeirOption} ->
                    RequestedAccess = table_access(Access),
                    Options0 = [
                        table_type(Type),
                        private,
                        {read_concurrency, ReadConcurrency},
                        {write_concurrency, WriteConcurrency}
                    ],
                    Options1 = case Named of
                        true -> [named_table | Options0];
                        false -> Options0
                    end,
                    %% Keep the table private until its TID is captured. Then
                    %% publish requested access and its heir in one setopts call.
                    Created = try ets:new(AtomName, Options1) of
                        Table when is_atom(Table) ->
                            %% A name can be reused after deletion; retain the instance.
                            {ok, ets:whereis(Table)};
                        Table -> {ok, Table}
                    catch
                        error:badarg ->
                            creation_error(AtomName, Named)
                    end,
                    case Created of
                        {ok, TableId} ->
                            finish_creation(TableId, HeirOption, RequestedAccess);
                        {error, Error} -> {error, Error}
                    end
            end
    end.

-spec insert(ets:table(), term(), term()) ->
    {ok, nil} | {error, atom()}.
insert(Table, Key, Value) ->
    try ets:insert(Table, {Key, Value}) of
        true -> {ok, nil}
    catch
        error:badarg -> table_error(Table)
    end.

-spec lookup(ets:table(), term()) ->
    {ok, none | {some, term()}} | {error, atom()}.
lookup(Table, Key) ->
    try ets:lookup(Table, Key) of
        [] -> {ok, none};
        [{_, Value} | _] -> {ok, {some, Value}}
    catch
        error:badarg -> table_error(Table)
    end.

-spec delete(ets:table()) -> {ok, nil} | {error, atom()}.
delete(Table) ->
    case table_owner(Table) of
        undefined -> {error, table_does_not_exist};
        Owner when Owner =/= self() -> {error, access_denied};
        _ ->
            try ets:delete(Table) of
                true -> {ok, nil}
            catch
                error:badarg -> table_error(Table)
            end
    end.

-spec exists(ets:table()) -> boolean().
exists(Table) ->
    table_exists(Table).

-spec owner(ets:table()) -> {ok, pid()} | {error, atom()}.
owner(Table) ->
    case table_owner(Table) of
        undefined -> {error, table_does_not_exist};
        Owner -> {ok, Owner}
    end.

-spec heir(ets:table()) -> {ok, none | {some, pid()}} | {error, atom()}.
heir(Table) ->
    try ets:info(Table, heir) of
        undefined -> {error, table_does_not_exist};
        none -> {ok, none};
        Pid when is_pid(Pid) -> {ok, {some, Pid}}
    catch
        error:badarg -> {error, table_does_not_exist}
    end.

-spec set_heir(ets:table(), pid(), term()) ->
    {ok, nil} | {error, atom()}.
set_heir(Table, Heir, Data) ->
    case ownership_precheck(Table) of
        {error, Error} -> {error, Error};
        ok ->
            case valid_local_process(Heir) of
                false -> {error, invalid_ownership_heir};
                true ->
                    try ets:setopts(Table, {heir, Heir, transfer_data(Table, Data)}) of
                        true -> {ok, nil}
                    catch
                        error:badarg -> ownership_error(Table)
                    end
            end
    end.

-spec clear_heir(ets:table()) -> {ok, nil} | {error, atom()}.
clear_heir(Table) ->
    case ownership_precheck(Table) of
        {error, Error} -> {error, Error};
        ok ->
            try ets:setopts(Table, {heir, none}) of
                true -> {ok, nil}
            catch
                error:badarg -> ownership_error(Table)
            end
    end.

-spec give_away(ets:table(), pid(), term()) ->
    {ok, nil} | {error, atom()}.
give_away(Table, Recipient, Data) ->
    case ownership_precheck(Table) of
        {error, Error} -> {error, Error};
        ok when Recipient =:= self() -> {error, recipient_is_owner};
        ok when not is_pid(Recipient) -> {error, recipient_not_alive};
        ok when node(Recipient) =/= node() -> {error, recipient_not_local};
        ok ->
            case is_process_alive(Recipient) of
                false -> {error, recipient_not_alive};
                true ->
                    try ets:give_away(Table, Recipient, transfer_data(Table, Data)) of
                        true -> {ok, nil}
                    catch
                        error:badarg -> ownership_error(Table)
                    end
            end
    end.

-spec validate_transfer(term()) ->
    {ok, {ets:tid(), pid(), term()}} | {error, atom()}.
validate_transfer({'ETS-TRANSFER', NativeTable, PreviousOwner,
                   {?TRANSFER_TAG, Candidate, Data}}) ->
    validate_instance_transfer(NativeTable, Candidate, PreviousOwner, Data);
validate_transfer({'ETS-TRANSFER', Candidate, PreviousOwner, Data}) ->
    %% Untagged native transfers are safe only with an instance-specific TID.
    validate_instance_transfer(Candidate, Candidate, PreviousOwner, Data);
validate_transfer(_) ->
    {error, invalid_transfer_message}.

validate_instance_transfer(NativeTable, Candidate, PreviousOwner, Data) ->
    %% Use the opaque TID returned by ETS, accepting only the exact candidate.
    %% A name resolves to a different term and cannot establish a generation.
    try ets:info(Candidate, id) of
        undefined -> {error, invalid_table};
        Table when Table =:= Candidate ->
            case transfer_table_matches(NativeTable, Table) of
                false -> {error, invalid_table};
                true when not is_pid(PreviousOwner) ->
                    {error, invalid_previous_owner};
                true -> {ok, {Table, PreviousOwner, Data}}
            end;
        _ -> {error, invalid_table}
    catch
        error:badarg -> {error, invalid_table}
    end.

transfer_table_matches(Table, Table) ->
    true;
transfer_table_matches(Name, Table) when is_atom(Name) ->
    ets:info(Table, named_table) =:= true andalso ets:info(Table, name) =:= Name;
transfer_table_matches(_, _) ->
    false.

transfer_data(Table, Data) ->
    {?TRANSFER_TAG, ets:info(Table, id), Data}.

finish_creation(Table, HeirOption, Access) ->
    Protection = {protection, Access},
    Options = case HeirOption of
        none -> [Protection];
        {heir, Pid, Data} ->
            [{heir, Pid, transfer_data(Table, Data)}, Protection]
    end,
    %% OTP 27/28 support protection changes despite their Erlang docs/specs
    %% listing only heir options. All options are validated before any mutation.
    try ets:setopts(Table, Options) of
        true -> {ok, Table}
    catch
        error:badarg ->
            %% A failed setopts leaves the table private, so only its creator
            %% can delete it. Clean up this exact TID, never the reusable name.
            case delete(Table) of
                {ok, nil} ->
                    case HeirOption of
                        none -> {error, invalid_options};
                        {heir, _, _} -> {error, invalid_heir}
                    end;
                {error, table_does_not_exist} -> {error, invalid_options}
            end
    end.

table_name(Name, Named) when is_binary(Name) ->
    case unicode:characters_to_list(Name, utf8) of
        Characters when is_list(Characters), length(Characters) =< 255 ->
            case Named of
                false ->
                    %% Validate every label, but intern only registered names.
                    {ok, beryl_heirloom};
                true ->
                    try binary_to_atom(Name, utf8) of
                        Atom -> {ok, Atom}
                    catch
                        error:badarg -> {error, invalid_name}
                    end
            end;
        _ ->
            {error, invalid_name}
    end;
table_name(_, _) ->
    {error, invalid_name}.

table_type(set) -> set;
table_type(ordered_set) -> ordered_set;
table_type(bag) -> bag;
table_type(duplicate_bag) -> duplicate_bag.

table_access(private) -> private;
table_access(protected) -> protected;
table_access(public) -> public.

heir_option(no_heir) ->
    {ok, none};
heir_option({heir, Pid, Data}) ->
    case valid_local_process(Pid) of
        true -> {ok, {heir, Pid, Data}};
        false -> {error, invalid_heir}
    end.

valid_local_process(Pid) ->
    is_pid(Pid) andalso node(Pid) =:= node() andalso is_process_alive(Pid).

creation_error(Name, true) ->
    case ets:whereis(Name) of
        undefined -> {error, invalid_options};
        _ -> {error, table_already_exists}
    end;
creation_error(_Name, false) ->
    {error, invalid_options}.

table_error(Table) ->
    case table_exists(Table) of
        false -> {error, table_does_not_exist};
        true -> {error, access_denied}
    end.

ownership_precheck(Table) ->
    case table_owner(Table) of
        undefined -> {error, ownership_table_does_not_exist};
        Owner when Owner =/= self() -> {error, not_owner};
        _ -> ok
    end.

ownership_error(Table) ->
    case ownership_precheck(Table) of
        {error, Error} -> {error, Error};
        ok -> {error, invalid_ownership_heir}
    end.

table_exists(Table) ->
    try ets:info(Table) of
        undefined -> false;
        _ -> true
    catch
        error:badarg -> false
    end.

table_owner(Table) ->
    try ets:info(Table, owner) of
        Owner -> Owner
    catch
        error:badarg -> undefined
    end.
