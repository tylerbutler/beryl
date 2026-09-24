-module(beryl_ewe_transport_test_ffi).
-export([connect_websocket/2, connect_websocket_with_origin/3,
         websocket_upgrade_status/2, websocket_upgrade_status_with_origin/3,
         send_text/2, send_binary/2, receive_text/2, receive_binary/2,
         close/1, http_get/2, stop_supervisor/1,
         suspend_server_peer/1, resume_process/1, outbound_queue_usage/1,
         attach_transport_events/0, detach_transport_events/1,
         receive_upgrade_event/1, receive_frame_event/1,
         receive_message_event/1, coalesced_upgrade_frames/0,
         split_upgrade_frames/0, empty_text_control_frames/0,
         empty_binary_frames/0]).

attach_transport_events() ->
    HandlerId = {beryl_ewe_transport_test, make_ref()},
    Self = self(),
    ok = telemetry:attach_many(
        HandlerId,
        [[beryl, transport, upgrade, stop],
         [beryl, transport, frame, stop],
         [beryl, channel, message, stop]],
        fun(Event, Measurements, Metadata, _Config) ->
            Self ! {beryl_transport_test, Event, Measurements, Metadata}
        end,
        nil
    ),
    HandlerId.

detach_transport_events(HandlerId) ->
    ok = telemetry:detach(HandlerId),
    flush_transport_events(),
    nil.

receive_upgrade_event(Timeout) ->
    receive
        {
            beryl_transport_test,
            [beryl, transport, upgrade, stop],
            #{count := 1, duration := Duration},
            #{transport := Transport, outcome := Outcome} = Metadata
        } when is_integer(Duration), Duration >= 0, map_size(Metadata) =:= 2 ->
            {ok, {atom_to_binary(Transport), atom_to_binary(Outcome)}}
    after
        Timeout -> {error, nil}
    end.

receive_frame_event(Timeout) ->
    receive
        {
            beryl_transport_test,
            [beryl, transport, frame, stop],
            #{count := 1, duration := Duration, bytes := Bytes},
            #{
                transport := Transport,
                frame_type := FrameType,
                outcome := Outcome
            } = Metadata
        } when is_integer(Duration), Duration >= 0, is_integer(Bytes),
               map_size(Metadata) =:= 3 ->
            {ok, {
                atom_to_binary(Transport),
                atom_to_binary(FrameType),
                atom_to_binary(Outcome),
                Bytes
            }}
    after
        Timeout -> {error, nil}
    end.

receive_message_event(Timeout) ->
    receive
        {
            beryl_transport_test,
            [beryl, channel, message, stop],
            #{count := 1, duration := Duration},
            #{
                kind := Kind,
                outcome := Outcome,
                callback_result := CallbackResult
            } = Metadata
        } when is_integer(Duration), Duration >= 0, map_size(Metadata) =:= 3 ->
            {ok, {
                atom_to_binary(Kind),
                atom_to_binary(Outcome),
                atom_to_binary(CallbackResult)
            }}
    after
        Timeout -> {error, nil}
    end.

flush_transport_events() ->
    receive
        {beryl_transport_test, _Event, _Measurements, _Metadata} ->
            flush_transport_events()
    after
        0 -> ok
    end.

%% Stop a supervisor process cleanly.
%% Unlinks first so the calling process is not affected, then sends
%% a shutdown exit signal which the supervisor handles by terminating
%% all children before itself.
stop_supervisor(Pid) ->
    erlang:unlink(Pid),
    MRef = erlang:monitor(process, Pid),
    erlang:exit(Pid, shutdown),
    receive
        {'DOWN', MRef, process, Pid, _Reason} -> nil
    after
        5000 ->
            erlang:demonitor(MRef, [flush]),
            erlang:exit(Pid, kill),
            nil
    end.

http_get(Port, Path) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = [
                <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
                <<"Host: 127.0.0.1:">>, integer_to_binary(Port), <<"\r\n">>,
                <<"Connection: close\r\n\r\n">>
            ],
            case gen_tcp:send(Socket, Request) of
                ok ->
                    Result =
                        case read_headers(Socket, <<>>) of
                            {ok, Headers} -> parse_status(Headers);
                            {error, nil} -> {error, nil}
                        end,
                    gen_tcp:close(Socket),
                    Result;
                _ ->
                    gen_tcp:close(Socket),
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

parse_status(Headers) ->
    case binary:split(Headers, <<"\r\n">>) of
        [StatusLine | _] ->
            case binary:split(StatusLine, <<" ">>, [global]) of
                [_Version, Code | _] ->
                    case string:to_integer(binary_to_list(Code)) of
                        {Int, _} when is_integer(Int) -> {ok, Int};
                        _ -> {error, nil}
                    end;
                _ ->
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

connect_websocket(Port, Path) ->
    connect_websocket_with_headers(Port, Path, []).

connect_websocket_with_origin(Port, Path, Origin) ->
    connect_websocket_with_headers(Port, Path, [
        <<"Origin: ">>, Origin, <<"\r\n">>
    ]).

websocket_upgrade_status_with_origin(Port, Path, Origin) ->
    websocket_upgrade_status_with_headers(Port, Path, [
        <<"Origin: ">>, Origin, <<"\r\n">>
    ]).

connect_websocket_with_headers(Port, Path, ExtraHeaders) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = websocket_request(Port, Path, ExtraHeaders),
            case gen_tcp:send(Socket, Request) of
                ok ->
                    case read_headers(Socket, <<>>) of
                        {ok, Headers} ->
                            case binary:match(Headers, <<" 101 ">>) of
                                nomatch ->
                                    gen_tcp:close(Socket),
                                    {error, nil};
                                _ ->
                                    {ok, Socket}
                            end;
                        {error, nil} ->
                            gen_tcp:close(Socket),
                            {error, nil}
                    end;
                _ ->
                    gen_tcp:close(Socket),
                    {error, nil}
            end;
        _ ->
            {error, nil}
    end.

websocket_upgrade_status(Port, Path) ->
    websocket_upgrade_status_with_headers(Port, Path, []).

websocket_upgrade_status_with_headers(Port, Path, ExtraHeaders) ->
    case gen_tcp:connect("127.0.0.1", Port, [binary, {active, false}], 5000) of
        {ok, Socket} ->
            Request = websocket_request(Port, Path, ExtraHeaders),
            Result =
                case gen_tcp:send(Socket, Request) of
                    ok ->
                        case read_headers(Socket, <<>>) of
                            {ok, Headers} -> parse_status(Headers);
                            {error, nil} -> {error, nil}
                        end;
                    _ ->
                        {error, nil}
                end,
            gen_tcp:close(Socket),
            Result;
        _ ->
            {error, nil}
    end.

websocket_request(Port, Path, ExtraHeaders) ->
    Key = base64:encode(crypto:strong_rand_bytes(16)),
    [
        <<"GET ">>, Path, <<" HTTP/1.1\r\n">>,
        <<"Host: 127.0.0.1:">>, integer_to_binary(Port), <<"\r\n">>,
        <<"Upgrade: websocket\r\n">>,
        <<"Connection: Upgrade\r\n">>,
        <<"Sec-WebSocket-Key: ">>, Key, <<"\r\n">>,
        <<"Sec-WebSocket-Version: 13\r\n">>,
        ExtraHeaders,
        <<"\r\n">>
    ].

send_text(Socket, Text) ->
    Mask = crypto:strong_rand_bytes(4),
    Payload = mask_payload(Text, Mask),
    Frame = [<<16#81>>, encode_client_length(byte_size(Text)), Mask, Payload],
    case gen_tcp:send(Socket, Frame) of
        ok -> {ok, Socket};
        _ -> {error, nil}
    end.

send_binary(Socket, Data) ->
    Mask = crypto:strong_rand_bytes(4),
    Payload = mask_payload(Data, Mask),
    Frame = [<<16#82>>, encode_client_length(byte_size(Data)), Mask, Payload],
    case gen_tcp:send(Socket, Frame) of
        ok -> {ok, Socket};
        _ -> {error, nil}
    end.

receive_text(Socket, Timeout) ->
    case read_frame(Socket, Timeout) of
        {text, Text} -> {ok, Text};
        skip -> receive_text(Socket, Timeout);
        _ -> {error, nil}
    end.

receive_binary(Socket, Timeout) ->
    case read_frame(Socket, Timeout) of
        {binary, Data} -> {ok, Data};
        skip -> receive_binary(Socket, Timeout);
        _ -> {error, nil}
    end.

close(Socket) ->
    _ = gen_tcp:send(Socket, <<16#88, 16#80, 0, 0, 0, 0>>),
    gen_tcp:close(Socket),
    nil.

suspend_server_peer(Socket) ->
    {ok, Peer} = inet:sockname(Socket),
    case find_server_peer(erlang:ports(), Peer) of
        {ok, Pid} ->
            true = erlang:suspend_process(Pid),
            {ok, Pid};
        error ->
            {error, nil}
    end.

find_server_peer([], _Peer) ->
    error;
find_server_peer([Port | Rest], Peer) ->
    case inet:peername(Port) of
        {ok, Peer} ->
            case erlang:port_info(Port, connected) of
                {connected, Pid} -> {ok, Pid};
                _ -> find_server_peer(Rest, Peer)
            end;
        _ ->
            find_server_peer(Rest, Peer)
    end.

resume_process(Pid) ->
    true = erlang:resume_process(Pid),
    nil.

outbound_queue_usage(Pid) ->
    {messages, Messages} = erlang:process_info(Pid, messages),
    lists:foldl(fun
        ({_Tag, {send_text, _Payload, Bytes}}, {Frames, TotalBytes}) ->
            {Frames + 1, TotalBytes + Bytes};
        ({_Tag, {send_binary, _Payload, Bytes}}, {Frames, TotalBytes}) ->
            {Frames + 1, TotalBytes + Bytes};
        (_, Usage) ->
            Usage
    end, {0, 0}, Messages).

read_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_headers(Socket, <<Acc/binary, Chunk/binary>>);
                _ -> {error, nil}
            end;
        {Start, MarkerLength} ->
            HeaderLength = Start + MarkerLength,
            <<Headers:HeaderLength/binary, Rest/binary>> = Acc,
            case Rest of
                <<>> ->
                    {ok, Headers};
                _ ->
                    case gen_tcp:unrecv(Socket, Rest) of
                        ok -> {ok, Headers};
                        _ -> {error, nil}
                    end
            end
    end.

coalesced_upgrade_frames() ->
    run_upgrade_server([[
        upgrade_response(),
        websocket_frame(<<"first">>),
        websocket_frame(<<"second">>)
    ]], 2).

split_upgrade_frames() ->
    run_upgrade_server([
        <<"HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\n">>,
        [<<"Connection: Upgrade\r\n\r\n">>, <<16#81>>],
        [
            <<5>>, <<"third">>,
            websocket_frame(<<"fourth">>)
        ]
    ], 2).

empty_text_control_frames() ->
    run_upgrade_reader([[
        upgrade_response(),
        websocket_frame(<<>>),
        <<16#89, 0>>,
        <<16#8a, 0>>,
        <<16#81, 16#80, 0, 0, 0, 0>>,
        websocket_frame(<<"next">>),
        <<16#88, 0>>
    ]], fun(Socket) ->
        case receive_text_frames(Socket, 3, []) of
            {ok, Frames} ->
                case read_frame(Socket, 1000) of
                    closed -> {ok, Frames};
                    _ -> {error, nil}
                end;
            {error, nil} ->
                {error, nil}
        end
    end).

empty_binary_frames() ->
    run_upgrade_reader([[
        upgrade_response(),
        websocket_binary_frame(<<>>),
        websocket_binary_frame(<<"next">>)
    ]], fun(Socket) ->
        receive_binary_frames(Socket, 2, [])
    end).

run_upgrade_server(Chunks, FrameCount) ->
    run_upgrade_reader(Chunks, fun(Socket) ->
        receive_text_frames(Socket, FrameCount, [])
    end).

run_upgrade_reader(Chunks, Reader) ->
    {ok, ListenSocket} = gen_tcp:listen(
        0,
        [binary, {active, false}, {reuseaddr, true}]
    ),
    {ok, {_Address, Port}} = inet:sockname(ListenSocket),
    {ServerPid, MonitorRef} = spawn_monitor(fun() ->
        serve_upgrade(ListenSocket, Chunks)
    end),
    Result =
        case connect_websocket(Port, <<"/socket">>) of
            {ok, Socket} ->
                Frames = Reader(Socket),
                close(Socket),
                Frames;
            {error, nil} ->
                {error, nil}
        end,
    gen_tcp:close(ListenSocket),
    receive
        {'DOWN', MonitorRef, process, ServerPid, normal} -> Result;
        {'DOWN', MonitorRef, process, ServerPid, _Reason} -> {error, nil}
    after
        5000 -> {error, nil}
    end.

serve_upgrade(ListenSocket, Chunks) ->
    {ok, Socket} = gen_tcp:accept(ListenSocket, 5000),
    {ok, _Request} = read_headers(Socket, <<>>),
    ok = send_chunks(Socket, Chunks),
    gen_tcp:close(Socket).

send_chunks(_Socket, []) ->
    ok;
send_chunks(Socket, [Chunk | Rest]) ->
    ok = gen_tcp:send(Socket, Chunk),
    case Rest of
        [] ->
            ok;
        _ ->
            timer:sleep(25),
            send_chunks(Socket, Rest)
    end.

receive_text_frames(_Socket, 0, Acc) ->
    {ok, lists:reverse(Acc)};
receive_text_frames(Socket, Count, Acc) ->
    case receive_text(Socket, 1000) of
        {ok, Text} ->
            receive_text_frames(Socket, Count - 1, [Text | Acc]);
        {error, nil} ->
            {error, nil}
    end.

receive_binary_frames(_Socket, 0, Acc) ->
    {ok, lists:reverse(Acc)};
receive_binary_frames(Socket, Count, Acc) ->
    case receive_binary(Socket, 1000) of
        {ok, Data} ->
            receive_binary_frames(Socket, Count - 1, [Data | Acc]);
        {error, nil} ->
            {error, nil}
    end.

upgrade_response() ->
    <<"HTTP/1.1 101 Switching Protocols\r\n",
      "Upgrade: websocket\r\n",
      "Connection: Upgrade\r\n\r\n">>.

websocket_frame(Payload) when byte_size(Payload) < 126 ->
    <<16#81, (byte_size(Payload)), Payload/binary>>.

websocket_binary_frame(Payload) when byte_size(Payload) < 126 ->
    <<16#82, (byte_size(Payload)), Payload/binary>>.

encode_client_length(Len) when Len < 126 ->
    <<(16#80 bor Len)>>;
encode_client_length(Len) when Len =< 65535 ->
    <<(16#80 bor 126), Len:16/big>>;
encode_client_length(Len) ->
    <<(16#80 bor 127), Len:64/big>>.

read_frame(Socket, Timeout) ->
    case gen_tcp:recv(Socket, 2, Timeout) of
        {ok, <<B1, B2>>} ->
            Opcode = B1 band 16#0f,
            Masked = (B2 band 16#80) =/= 0,
            Len0 = B2 band 16#7f,
            case read_payload(Socket, Timeout, Masked, Len0) of
                {ok, Payload} ->
                    case Opcode of
                        1 -> {text, Payload};
                        2 -> {binary, Payload};
                        8 -> closed;
                        9 -> skip;
                        10 -> skip;
                        _ -> skip
                    end;
                Error -> Error
            end;
        _ ->
            {error, nil}
    end.

read_payload(Socket, Timeout, Masked, Len0) ->
    case read_length(Socket, Timeout, Len0) of
        {ok, Len} ->
            case read_mask(Socket, Timeout, Masked) of
                {ok, Mask} ->
                    case read_payload_bytes(Socket, Timeout, Len) of
                        {ok, Payload} ->
                            case Mask of
                                none -> {ok, Payload};
                                _ -> {ok, mask_payload(Payload, Mask)}
                            end;
                        _ -> {error, nil}
                    end;
                Error -> Error
            end;
        Error -> Error
    end.

read_payload_bytes(_Socket, _Timeout, 0) ->
    {ok, <<>>};
read_payload_bytes(Socket, Timeout, Len) ->
    gen_tcp:recv(Socket, Len, Timeout).

read_length(_Socket, _Timeout, Len) when Len < 126 ->
    {ok, Len};
read_length(Socket, Timeout, 126) ->
    case gen_tcp:recv(Socket, 2, Timeout) of
        {ok, <<Len:16/big>>} -> {ok, Len};
        _ -> {error, nil}
    end;
read_length(Socket, Timeout, 127) ->
    case gen_tcp:recv(Socket, 8, Timeout) of
        {ok, <<Len:64/big>>} -> {ok, Len};
        _ -> {error, nil}
    end.

read_mask(Socket, Timeout, true) ->
    case gen_tcp:recv(Socket, 4, Timeout) of
        {ok, Mask} -> {ok, Mask};
        _ -> {error, nil}
    end;
read_mask(_Socket, _Timeout, false) ->
    {ok, none}.

mask_payload(Payload, <<M1, M2, M3, M4>>) ->
    mask_payload(Payload, <<M1, M2, M3, M4>>, 0, <<>>).

mask_payload(<<>>, _Mask, _Index, Acc) ->
    Acc;
mask_payload(<<Byte, Rest/binary>>, Mask, Index, Acc) ->
    MaskByte = binary:at(Mask, Index rem 4),
    mask_payload(Rest, Mask, Index + 1, <<Acc/binary, (Byte bxor MaskByte)>>).
