-module(beryl_ewe_compression_test_ffi).
-export([fixture/1, malformed/0]).

%% These are deliberately raw terms: layout compatibility and malformed
%% connections cannot be expressed as values of Ewe's opaque Connection type.
%% Both returned values share the same unique resource sentinels. Gleam
%% compares the entire result, not just the extension field.
fixture(websocket) ->
    upgrade_pair(
        {some, {websocket_upgrade, {some, <<"key">>}, {some, <<"13">>},
                {some, <<"permessage-deflate">>}}},
        {some, {websocket_upgrade, {some, <<"key">>}, {some, <<"13">>}, none}}
    );
fixture(missing_handshake_fields) ->
    upgrade_pair(
        {some, {websocket_upgrade, none, none, {some, <<"permessage-deflate">>}}},
        {some, {websocket_upgrade, none, none, none}}
    );
fixture(no_extensions) ->
    Upgrade = {some, {websocket_upgrade, {some, <<"key">>}, {some, <<"13">>}, none}},
    upgrade_pair(Upgrade, Upgrade);
fixture(other_upgrade) ->
    Upgrade = {some, {other_upgrade, <<"h2c">>}},
    upgrade_pair(Upgrade, Upgrade);
fixture(no_upgrade) ->
    upgrade_pair(none, none);
fixture(http2) ->
    Connection =
        {http2, {connection, make_ref(), 17, true, [<<"pending">>],
                 [{<<"trailer">>, <<"value">>}], 321, 987,
                 {{127, 0, 0, 1}, 4321}, {some, <<"websocket">>}}},
    {Connection, Connection}.

upgrade_pair(Upgrade, ExpectedUpgrade) ->
    Transport = make_ref(),
    Socket = make_ref(),
    Peer = {{127, 0, 0, 1}, 4321},
    Self = self(),
    Buffer = <<0, 1, 2, 255>>,
    Framing = make_ref(),
    Read = 123,
    ChunkRemaining = 456,
    Options = #{sentinel => make_ref()},
    ExpectContinue = true,
    {{http1, {connection, Transport, Socket, Peer, Self, Buffer, Framing,
              Read, ChunkRemaining, Options, Upgrade, ExpectContinue}},
     {http1, {connection, Transport, Socket, Peer, Self, Buffer, Framing,
              Read, ChunkRemaining, Options, ExpectedUpgrade, ExpectContinue}}}.

malformed() ->
    [
        nil,
        {http1, {connection}},
        {http1, {unexpected_tag, a, b, c, d, e, f, g, h, i, none, j}},
        {http2, {connection}},
        {http3, {connection}},
        bad_upgrade({some, {websocket_upgrade, none, none}}),
        bad_upgrade({some, {websocket_upgrade, <<"not-an-option">>, none, none}}),
        bad_upgrade({some, {websocket_upgrade, none, {some, 13}, none}}),
        bad_upgrade({some, {websocket_upgrade, none, none, {some, []}}}),
        bad_upgrade({some, {other_upgrade, 42}}),
        bad_upgrade({some, {unknown_upgrade, <<"websocket">>}}),
        bad_upgrade({unexpected_option, none})
    ].

bad_upgrade(Upgrade) ->
    {Connection, _} = upgrade_pair(Upgrade, Upgrade),
    Connection.
