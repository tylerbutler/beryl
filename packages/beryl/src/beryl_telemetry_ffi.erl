-module(beryl_telemetry_ffi).
-export([execute/1, monotonic_time/0, mailbox_length/0]).

execute({transport_upgrade_stop, Duration, Transport, Outcome}) ->
    telemetry:execute(
        [beryl, transport, upgrade, stop],
        #{count => 1, duration => Duration},
        #{transport => transport(Transport), outcome => outcome(Outcome)}
    );
execute({transport_frame_stop, Duration, Bytes, Transport, Kind, Outcome}) ->
    telemetry:execute(
        [beryl, transport, frame, stop],
        #{count => 1, duration => Duration, bytes => Bytes},
        #{
            transport => transport(Transport),
            frame_type => frame_kind(Kind),
            outcome => outcome(Outcome)
        }
    );
execute(socket_connected) ->
    telemetry:execute([beryl, socket, connected], #{count => 1}, #{});
execute({socket_disconnected, Duration, JoinedChannels, Reason}) ->
    telemetry:execute(
        [beryl, socket, disconnected],
        #{
            count => 1,
            duration => Duration,
            joined_channels => JoinedChannels
        },
        #{reason => disconnect_reason(Reason)}
    );
execute({channel_join_stop, Duration, Outcome}) ->
    telemetry:execute(
        [beryl, channel, join, stop],
        #{count => 1, duration => Duration},
        #{outcome => outcome(Outcome)}
    );
execute({channel_message_stop, Duration, Kind, Outcome, CallbackResult}) ->
    telemetry:execute(
        [beryl, channel, message, stop],
        #{count => 1, duration => Duration},
        #{
            kind => message_kind(Kind),
            outcome => outcome(Outcome),
            callback_result => callback_result(CallbackResult)
        }
    );
execute({broadcast_stop, Duration, Recipients, SendFailures, Origin}) ->
    telemetry:execute(
        [beryl, broadcast, stop],
        #{
            count => 1,
            duration => Duration,
            recipients => Recipients,
            send_failures => SendFailures
        },
        #{origin => broadcast_origin(Origin)}
    ).

monotonic_time() ->
    erlang:monotonic_time().

mailbox_length() ->
    {message_queue_len, Length} =
        erlang:process_info(erlang:self(), message_queue_len),
    Length.

transport(mist) -> mist;
transport(ewe) -> ewe.

outcome(success) -> success;
outcome(rejected) -> rejected;
outcome(dropped) -> dropped;
outcome(rate_limited) -> rate_limited;
outcome(invalid) -> invalid;
outcome(failed) -> failed.

frame_kind(text_frame) -> text;
frame_kind(binary_frame) -> binary.

message_kind(text_message) -> text;
message_kind(binary_message) -> binary;
message_kind(info_message) -> info;
message_kind(heartbeat_message) -> heartbeat.

callback_result(no_reply) -> no_reply;
callback_result(reply) -> reply;
callback_result(reply_error) -> reply_error;
callback_result(push) -> push;
callback_result(stop) -> stop;
callback_result(callback_failed) -> failed.

disconnect_reason(client_closed) -> client_closed;
disconnect_reason(transport_closed) -> transport_closed;
disconnect_reason(heartbeat_timeout) -> heartbeat_timeout;
disconnect_reason(server_shutdown) -> server_shutdown;
disconnect_reason(disconnect_failed) -> failed.

broadcast_origin(local) -> local;
broadcast_origin(remote) -> remote.
