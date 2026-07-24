-module(beryl_pubsub_ffi).
-export([start_pg_scope/1, join_group/3, leave_group/3,
         get_members/2, get_local_members/2]).

% pg:start returns {ok, Pid} or {error, {already_started, Pid}}; both are
% success for us, so normalise to nil for the Gleam side.
start_pg_scope(Scope) ->
    _ = pg:start(Scope),
    nil.

join_group(Scope, Group, Pid) ->
    ok = pg:join(Scope, Group, Pid),
    nil.

% pg:leave returns ok | not_joined; leaving an unjoined group is a no-op.
leave_group(Scope, Group, Pid) ->
    _ = pg:leave(Scope, Group, Pid),
    nil.
get_members(Scope, Group) -> pg:get_members(Scope, Group).
get_local_members(Scope, Group) -> pg:get_local_members(Scope, Group).
