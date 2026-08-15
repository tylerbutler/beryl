-module(beryl_presence_state_ffi).
-export([remove_tag/2]).

%% lattice_presence 1.x exposes tuple-wide leave operations but not removal by
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
