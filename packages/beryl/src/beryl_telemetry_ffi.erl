-module(beryl_telemetry_ffi).
-export([execute/1, monotonic_time/0, mailbox_length/0]).

execute({transport_upgrade_stop, Duration, Transport, Outcome}) ->
    telemetry:execute(
        [beryl, transport, upgrade, stop],
        #{count => 1, duration => Duration},
        #{transport => transport(Transport), outcome => outcome(Outcome)}
    ),
    nil;
execute({transport_frame_stop, Duration, Bytes, Transport, Kind, Outcome}) ->
    telemetry:execute(
        [beryl, transport, frame, stop],
        #{count => 1, duration => Duration, bytes => Bytes},
        #{
            transport => transport(Transport),
            frame_type => frame_kind(Kind),
            outcome => outcome(Outcome)
        }
    ),
    nil;
execute(socket_connected) ->
    telemetry:execute([beryl, socket, connected], #{count => 1}, #{}),
    nil;
execute({socket_disconnected, Duration, JoinedTopics, Reason}) ->
    telemetry:execute(
        [beryl, socket, disconnected],
        #{
            count => 1,
            duration => Duration,
            joined_channels => JoinedTopics
        },
        #{reason => disconnect_reason(Reason)}
    ),
    nil;
execute({channel_join_stop, Duration, Outcome}) ->
    telemetry:execute(
        [beryl, channel, join, stop],
        #{count => 1, duration => Duration},
        #{outcome => outcome(Outcome)}
    ),
    nil;
execute({channel_message_stop, Duration, Kind, Outcome, CallbackResult}) ->
    telemetry:execute(
        [beryl, channel, message, stop],
        #{count => 1, duration => Duration},
        #{
            kind => message_kind(Kind),
            outcome => outcome(Outcome),
            callback_result => callback_result(CallbackResult)
        }
    ),
    nil;
execute({broadcast_stop, Duration, Recipients, Origin}) ->
    telemetry:execute(
        [beryl, broadcast, stop],
        #{
            count => 1,
            duration => Duration,
            recipients => Recipients
        },
        #{origin => broadcast_origin(Origin)}
    ),
    nil.

monotonic_time() ->
    erlang:monotonic_time().

mailbox_length() ->
    {message_queue_len, Length} =
        erlang:process_info(erlang:self(), message_queue_len),
    Length.

transport(mist) -> mist;
transport(ewe) -> ewe.

outcome(upgrade_succeeded) -> success;
outcome(origin_rejected) -> origin_rejected;
outcome(version_rejected) -> version_rejected;
outcome(auth_rejected) -> auth_rejected;
outcome(capacity_rejected) -> capacity_rejected;
outcome(handshake_failed) -> handshake_failed;
outcome(frame_routed) -> routed;
outcome(frame_oversized) -> oversized;
outcome(frame_rate_limited) -> rate_limited;
outcome(frame_decode_failed) -> decode_failed;
outcome(join_accepted) -> accepted;
outcome(join_handler_rejected) -> handler_rejected;
outcome(join_no_handler) -> no_handler;
outcome(join_invalid_topic) -> invalid_topic;
outcome(join_topic_limit) -> topic_limit;
outcome(join_rate_limited) -> rate_limited;
outcome(join_callback_failed) -> callback_error;
outcome(join_socket_missing) -> socket_missing;
outcome(message_handled) -> handled;
outcome(message_unjoined) -> unjoined;
outcome(message_stale) -> stale;
outcome(message_invalid) -> invalid;
outcome(message_rate_limited) -> rate_limited;
outcome(message_callback_failed) -> callback_error;
outcome(message_socket_missing) -> socket_missing.

frame_kind(text_frame) -> text;
frame_kind(binary_frame) -> binary.

message_kind(text_message) -> text;
message_kind(binary_message) -> binary;
message_kind(info_message) -> info;
message_kind(heartbeat_message) -> heartbeat.

callback_result(no_reply) -> no_reply;
callback_result(not_applicable) -> not_applicable;
callback_result(reply) -> reply;
callback_result(reply_error) -> reply_error;
callback_result(push) -> push;
callback_result(stop) -> stop;
callback_result(callback_failed) -> failed.

disconnect_reason(normal_disconnect) -> normal;
disconnect_reason(heartbeat_timeout) -> heartbeat_timeout;
disconnect_reason(shutdown_disconnect) -> shutdown;
disconnect_reason(callback_disconnect) -> callback_error.

broadcast_origin(local) -> local;
broadcast_origin(remote) -> remote.
