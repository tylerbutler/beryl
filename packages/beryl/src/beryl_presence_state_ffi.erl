-module(beryl_presence_state_ffi).
-export([remove_tag/2, owner_snapshot/1]).

%% lattice_presence 2.x exposes tuple-wide leave operations but not removal by
%% its public Tag. Preserve every opaque state field while dropping one value.
remove_tag({state, Replica, Context, Clouds, Values, Replicas}, Tag)
  when is_map(Values) ->
    case maps:take(Tag, Values) of
        error ->
            {{state, Replica, Context, Clouds, Values, Replicas}, false};
        {_Entry, Remaining} ->
            {{state, Replica, Context, Clouds, Remaining, Replicas}, true}
    end;
remove_tag(_State, _Tag) ->
    erlang:error(unsupported_lattice_presence_state).

%% Keep only the data this replica owns.
%%
%% beryl replicates one full state per owner, so a reply must not carry
%% another replica's clocks. The lifecycle API retains a high-water clock for
%% every replica it removes; relaying those clocks would make the receiver
%% treat a peer's later entries as already observed.
owner_snapshot({state, Replica, Context, Clouds, Values, _Replicas})
  when is_map(Context), is_map(Clouds), is_map(Values) ->
    {state,
     Replica,
     maps:with([Replica], Context),
     maps:with([Replica], Clouds),
     maps:filter(fun({tag, Owner, _Clock}, _Entry) -> Owner =:= Replica end,
                 Values),
     #{Replica => up}};
owner_snapshot(_State) ->
    erlang:error(unsupported_lattice_presence_state).
