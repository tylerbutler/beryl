-module(showcase_harness_test_ffi).
-export([without_error_logs/1, log/2, socket_actor/2]).

-define(HANDLER_ID, showcase_harness_test_log_capture).

socket_actor(Router, SocketId) ->
    {registered_name, Name} = process_info(Router, registered_name),
    {ok, {Table, Router, _, _, _, _, _}} = beryl_work_queue_ffi:lookup(Name),
    [{state, #{targets := Targets}}] = ets:lookup(Table, state),
    {_Incarnation, {_, Owner, _, _, _, _, _}, _Status} =
        maps:get(SocketId, Targets),
    Owner.

without_error_logs(Action) ->
    _ = logger:remove_handler(?HANDLER_ID),
    ok = logger:add_handler(?HANDLER_ID, ?MODULE, #{config => #{pid => self()}}),
    try
        Action(),
        receive
            captured_error -> false
        after 100 ->
            true
        end
    after
        _ = logger:remove_handler(?HANDLER_ID)
    end.

log(#{level := error, msg := {report, [{palabres, _, _, _}]}},
    #{config := #{pid := Pid}}) ->
    Pid ! captured_error,
    ok;
log(_Event, _Config) ->
    ok.
