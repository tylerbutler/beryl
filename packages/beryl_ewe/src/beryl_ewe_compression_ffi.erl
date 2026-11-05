-module(beryl_ewe_compression_ffi).

-export([disable_cached_compression/1]).

%% shortcut: Ewe 9.0.0 private connection/upgrade layouts; replace this shim
%% with Ewe's public compression switch when one becomes available.
%% Pure copies only: sockets, subjects, buffers, and lifecycle ownership stay
%% with Ewe. Unknown layouts fail closed rather than retain compression.
-spec disable_cached_compression(term()) -> {ok, term()} | {error, nil}.
disable_cached_compression(
    {http1, {connection, Transport, Socket, Peer, Self, Buffer, Framing,
             Read, ChunkRemaining, Options, Upgrade, ExpectContinue}}
) ->
    case disable_upgrade(Upgrade) of
        {ok, Disabled} ->
            {ok, {http1, {connection, Transport, Socket, Peer, Self, Buffer,
                         Framing, Read, ChunkRemaining, Options, Disabled,
                         ExpectContinue}}};
        {error, nil} ->
            {error, nil}
    end;
disable_cached_compression(
    {http2, {connection, _Commands, _StreamId, _HasBody, _Pending,
             _PendingTrailers, _BytesRead, _BodyReadTimeout, _Peer, _Protocol}}
    = Connection
) ->
    {ok, Connection};
disable_cached_compression(_) ->
    {error, nil}.

-spec disable_upgrade(term()) -> {ok, term()} | {error, nil}.
disable_upgrade(none) ->
    {ok, none};
disable_upgrade({some, {other_upgrade, Name}} = Upgrade) when is_binary(Name) ->
    {ok, Upgrade};
disable_upgrade({some, {websocket_upgrade, Key, Version, Extensions}}) ->
    case optional_string(Key) andalso optional_string(Version)
         andalso optional_string(Extensions) of
        true ->
            %% Missing/invalid handshake values remain Ewe's responsibility.
            {ok, {some, {websocket_upgrade, Key, Version, none}}};
        false ->
            {error, nil}
    end;
disable_upgrade(_) ->
    {error, nil}.

-spec optional_string(term()) -> boolean().
optional_string(none) -> true;
optional_string({some, Value}) when is_binary(Value) -> true;
optional_string(_) -> false.
