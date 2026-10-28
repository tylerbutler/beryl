---
title: Portable channel hosts
description: Run the channel protocol on Erlang or JavaScript with host-owned I/O.
---

`beryl_protocol` provides pure channel lifecycle transitions on Erlang and
JavaScript. A host supplies decoded inputs and time, then executes the returned
actions in order. The core does not read a clock, write a socket, authenticate
a user, or run an application callback.

The BEAM `beryl` package uses the same transitions while retaining its actors,
supervision, queue budgets, PubSub, and presence. Mist and Ewe continue to use
the public transport SPI.

## Framing

The core works with normalized messages rather than bytes. The BEAM runtime
keeps its existing pluggable codec API, including Phoenix text and binary
support. The JavaScript example uses Roost for Phoenix framing.

See the
[Durable Object example](https://github.com/tylerbutler/beryl/tree/main/examples/portable_channels)
for a host that uses the official Phoenix JavaScript client.

## Execute actions in order

Keep one protocol state per connection. Process an input, store the next state,
then execute its actions in order. Feed application decisions and host cleanup
completions back through the core. Do not let a later input overtake unfinished
cleanup for that connection.

The host must finish the old topic instance's cleanup before it authorizes a
replacement join. Send the successful join reply before initial pushes.
Subscription admission, callback failure, send failure, and persistence failure
need explicit host handling. Do not continue with a partially executed action
list after an error.

The portable pending-operation limit bounds the core's ledger. A host must
also bound inbound frames, application queues, and retained bytes. The BEAM
runtime retains its existing count and byte admission budgets.

## Reply capabilities

Join and reply handles identify one operation in one channel generation and
connection. They do not derive identity from client-supplied references.
Reply handles are single use. Completion, discard, and final topic cleanup
release their capacity.

The BEAM adapter preserves the existing opaque `JoinRef` and `ReplyRef` API.
Applications return the exact handle they received. A stale completion must
not consume a newer request, even if the client reuses its wire references.

## Deadlines and restoration

The host schedules the next required deadline and supplies time when it runs
the expiry transition. Application traffic does not refresh the heartbeat
deadline. A delayed or duplicate timer must consult current protocol state.

Persist the core's versioned export together with a host save time.
Restore connection identity, channel generations, and operation counters before
accepting new work. Account for elapsed time during hibernation and rebase
deadlines onto the new runtime's clock. Do not compare monotonic timestamps
from different runtime instances.

Do not serialize callbacks, credentials, process handles, or queue reservations.
Invalidate application work that the host cannot recover. Require affected
channels to rejoin and authorize them again; return a fresh authoritative
snapshot. Invalid attachments require a reconnect.

## Application authority and command retries

Channel leave and transport disconnect do not imply that a player left an
application roster. The application owns that rule.

Phoenix references correlate protocol replies. A stable application command
ID and a durable deduplication record protect mutations against retries after
a lost reply or reconnect. Persist the mutation and its deduplication record
in the same transaction. The core cannot provide exactly-once application
execution or replace authorization and sequence checks.

The example uses one Durable Object per match, with a counter and a persistent
roster. It demonstrates hibernation, retries, and rejoin recovery without
changing or deploying Monk.
