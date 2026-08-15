-module(beryl_presence_read_ffi).
-export([new_table/0, put_topic/4, delete_topic/2, get_topic/2, get_count/2]).

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
%% readers never observe a partial topic snapshot. The count is stored
%% alongside the entries (rather than derived from them on read) so
%% `get_count/2` can fetch it in isolation via `ets:lookup_element/4`,
%% without copying the entry list out of the table.
put_topic(Table, Topic, Count, Entries) ->
    true = ets:insert(Table, {Topic, Count, Entries}),
    nil.

%% Remove a topic's snapshot entirely (used once a topic has no entries
%% left) so a missing topic reads as empty only because the table itself
%% has nothing recorded for it, not because of a stale leftover value.
delete_topic(Table, Topic) ->
    catch ets:delete(Table, Topic),
    nil.

%% Look up a topic's materialized entries.
%%
%% Returns `{found, Entries}` / `not_found` / `table_gone`, matching the
%% Gleam `TopicLookup` type's runtime representation exactly, so no
%% decoding is needed on the Gleam side. `table_gone` is distinguished from
%% `not_found` so callers can fail loudly when the table itself (and thus
%% the owning actor) is gone, rather than treating a dead actor the same as
%% a topic with no presences.
get_topic(Table, Topic) ->
    try ets:lookup(Table, Topic) of
        [{_, _Count, Entries}] -> {found, Entries};
        [] -> not_found
    catch
        error:badarg -> table_gone
    end.

%% Look up a topic's materialized count only, without touching its entry
%% list. `ets:lookup_element/4` reads (and copies) just the count field of
%% the `{Topic, Count, Entries}` row, so this stays O(1) with respect to the
%% number of entries in the topic, unlike `get_topic/2` followed by
%% `length/1`. The 4-arity form's default (`0`) covers a topic with no
%% recorded snapshot -- "never tracked" and "empty" both mean zero -- while
%% a missing *table* (the owning actor is gone) still raises `badarg`
%% regardless of that default, which is how `table_gone` is distinguished
%% from an ordinary zero count.
%%
%% Returns `{count_found, Count}` / `count_table_gone`, matching the Gleam
%% `CountLookup` type's runtime representation exactly.
get_count(Table, Topic) ->
    try ets:lookup_element(Table, Topic, 2, 0) of
        Count -> {count_found, Count}
    catch
        error:badarg -> count_table_gone
    end.
