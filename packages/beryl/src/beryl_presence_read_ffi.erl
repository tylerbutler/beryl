-module(beryl_presence_read_ffi).
-export([new_table/0, put_topic/3, delete_topic/2, get_topic/2]).

%% Create the materialized presence read-model table.
%%
%% Created by (and owned by) the presence actor process, so its lifetime is
%% tied to the actor: when the actor stops or crashes, the table is deleted
%% automatically along with it, and any read attempted afterward observes a
%% dead table rather than silently reading stale or empty data. The table is
%% `protected` so any process can read it directly (no actor call), while
%% only the owning (actor) process may write to it. Unnamed (no
%% `named_table`), so repeated actor starts never collide on a shared name.
new_table() ->
    ets:new(beryl_presence_reads, [set, protected, {read_concurrency, true}]).

%% Replace the materialized snapshot for a topic. Overwrites atomically:
%% `ets:insert/2` replaces any prior entry for the same key in one step, so
%% readers never observe a partial topic snapshot.
put_topic(Table, Topic, Entries) ->
    true = ets:insert(Table, {Topic, Entries}),
    nil.

%% Remove a topic's snapshot entirely (used once a topic has no entries
%% left) so a missing topic reads as empty only because the table itself
%% has nothing recorded for it, not because of a stale leftover value.
delete_topic(Table, Topic) ->
    catch ets:delete(Table, Topic),
    nil.

%% Look up a topic's materialized snapshot.
%%
%% Returns `{found, Entries}` / `not_found` / `table_gone`, matching the
%% Gleam `TopicLookup` type's runtime representation exactly, so no
%% decoding is needed on the Gleam side. `table_gone` is distinguished from
%% `not_found` so callers can fail loudly when the table itself (and thus
%% the owning actor) is gone, rather than treating a dead actor the same as
%% a topic with no presences.
get_topic(Table, Topic) ->
    try ets:lookup(Table, Topic) of
        [{_, Entries}] -> {found, Entries};
        [] -> not_found
    catch
        error:badarg -> table_gone
    end.
