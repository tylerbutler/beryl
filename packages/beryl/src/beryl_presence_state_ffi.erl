-module(beryl_presence_state_ffi).
-export([remove_tag/2, owner_snapshot/1]).

%% Temporary private-representation exception for lattice_presence >= 2.0.0
%% and < 2.1.0. Verified against 2.0.0 only, not future accepted patches.
%% Replace both operations when supported upstream APIs are available:
%% https://github.com/tylerbutler/lattice/issues/199
%%
%% Verified Erlang layout:
%% {state, Replica, Context, Clouds, Values, Replicas}
%% Replica is a Gleam String (UTF-8 binary). All four Dict fields are maps:
%% Context maps replicas to clocks; Clouds maps replicas to opaque Gleam Sets
%% of clocks; Values maps public {tag, Replica, Clock} tags to Entry values;
%% Replicas maps replicas to the status atoms up/down. Do not unpack Entries
%% or Sets here. Dependency upgrades require representation inspection and
%% compatibility plus replication tests, even within the accepted patch line.
%%
%% These pure functions own no processes or resources. They accept trusted
%% upstream States and Tags from Gleam, not arbitrary decoded input. Unsupported
%% tuple layouts or non-map dictionary fields raise
%% unsupported_lattice_presence_state (a process failure, not a Gleam Result).
%% These guards are deliberately not a recursive state/schema validator.
%%
%% Upstream leave removes every local entry matching pid/topic/key, not one
%% public Tag. Remove precisely that tag, reporting whether it existed, while
%% preserving every non-values field, including causal removal history.
remove_tag({state, Replica, Context, Clouds, Values, Replicas}, Tag)
  when is_map(Context), is_map(Clouds), is_map(Values), is_map(Replicas) ->
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
%% another replica's values, clocks, clouds, or liveness. Retain the owner's
%% identity and causal history even when it has no entries; mark only it up.
%% Upstream extract_full_state does not project ownership.
%% The lifecycle API retains a high-water clock for
%% every replica it removes; relaying those clocks would make the receiver
%% treat a peer's later entries as already observed.
owner_snapshot({state, Replica, Context, Clouds, Values, Replicas})
  when is_map(Context), is_map(Clouds), is_map(Values), is_map(Replicas) ->
    {state,
     Replica,
     maps:with([Replica], Context),
     maps:with([Replica], Clouds),
     maps:filter(fun({tag, Owner, _Clock}, _Entry) -> Owner =:= Replica end,
                 Values),
     #{Replica => up}};
owner_snapshot(_State) ->
    erlang:error(unsupported_lattice_presence_state).
