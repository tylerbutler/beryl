-module(beryl_presence_read_test_ffi).
-export([delete_absent_topic/0, delete_gone_table/0, delete_unowned_table/0]).

delete_absent_topic() ->
    Table = ets:new(?MODULE, [set, protected]),
    try beryl_presence_read_ffi:delete_topic(Table, <<"missing">>)
    after
        true = ets:delete(Table)
    end.

delete_gone_table() ->
    Table = ets:new(?MODULE, [set, protected]),
    true = ets:delete(Table),
    beryl_presence_read_ffi:delete_topic(Table, <<"missing">>).

delete_unowned_table() ->
    Parent = self(),
    {Owner, Monitor} = spawn_monitor(fun() ->
        Table = ets:new(?MODULE, [set, protected]),
        Parent ! {self(), Table},
        receive
            stop -> ok
        end
    end),
    receive
        {Owner, Table} ->
            Result = try
                beryl_presence_read_ffi:delete_topic(Table, <<"missing">>)
            after
                Owner ! stop
            end,
            receive
                {'DOWN', Monitor, process, Owner, normal} -> Result
            end
    end.
