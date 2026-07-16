-module(beryl_mist_transport_test_ffi).
-export([connect_websocket/2, connect_websocket_with_origin/3,
         websocket_upgrade_status/2, websocket_upgrade_status_with_origin/3,
         send_text/2, send_binary/2, receive_text/2, receive_binary/2,
         close/1, http_get/2, stop_supervisor/1]).

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

read_headers(Socket, Acc) ->
    case binary:match(Acc, <<"\r\n\r\n">>) of
        nomatch ->
            case gen_tcp:recv(Socket, 0, 5000) of
                {ok, Chunk} -> read_headers(Socket, <<Acc/binary, Chunk/binary>>);
                _ -> {error, nil}
            end;
        _ ->
            {ok, Acc}
    end.

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
                    case gen_tcp:recv(Socket, Len, Timeout) of
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
