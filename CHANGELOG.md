# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## v0.1.0 - 2026-02-28


#### Added

##### Add on_connect authentication hook to WebSocket transport config.

Allows rejecting unauthenticated connections before the WebSocket upgrade with a 403 response.


#### Fixed

##### CRDT next_clock now accounts for cloud values, preventing tag collision after non-contiguous merges.


#### Removed

##### Remove socket.topics() and socket.is_subscribed() from public API.

These functions always returned empty/false because the coordinator tracks subscriptions internally.

##### Remove unused info type parameter from Channel.

Channel type simplified from Channel(assigns, info) to Channel(assigns). The handle_info callback and with_handle_info builder are removed as they were never wired through the coordinator.


#### Security

##### Rate limiter now denies requests when token bucket creation fails (fail-closed), instead of silently allowing them through (fail-open).


