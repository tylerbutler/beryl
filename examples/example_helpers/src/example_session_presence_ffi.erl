-module(example_session_presence_ffi).
-export([new_store/0, track/4, untrack/3, count/2, snapshot/2]).

new_store() ->
    ets:new(?MODULE, [
        set,
        public,
        {read_concurrency, true},
        {write_concurrency, true}
    ]).

track(Table, Topic, SessionId, Meta) ->
    true = ets:insert(Table, {{Topic, SessionId}, Meta}),
    nil.

untrack(Table, Topic, SessionId) ->
    true = ets:delete(Table, {Topic, SessionId}),
    nil.

count(Table, Topic) ->
    ets:select_count(Table, [{{{Topic, '_'}, '_'}, [], [true]}]).

snapshot(Table, Topic) ->
    [
        {SessionId, Meta}
     || {{StoredTopic, SessionId}, Meta} <- ets:tab2list(Table),
        StoredTopic =:= Topic
    ].
