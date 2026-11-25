<a id="adr-0024"></a>

# 0024: Only the caller's deadline ends a call

Date: 2026-11-25
Status: Accepted

## Decision

- HTTP Gun sets Gun's `closing_timeout` to `infinity` in both the HTTP/1.1
  and the HTTP/2 options. Gun's closing state no longer ends a stream on a
  timer of its own.
- A call ends only at its own deadline, its idle bound, its cancellation, its
  body close, the end of the response, or a transport failure.
- A body owner whose client exits closes its Gun connection, so a connection
  never outlives the client that opened it.

## Rationale and alternatives

- In Gun 2.6.0, `gun_http` enters its closing state when a response carries
  `connection: close` while the stream is still active, and `gun_http2` enters
  it after a GOAWAY. The state arms `closing_timeout`, 15000 ms by default,
  and disconnects when it fires, even with a stream still receiving data.
  Every streamed response with `connection: close` was cut at 15 seconds,
  whatever deadline the caller had set, and surfaced as
  `RequestFailed(PeerClosed)`.
- The caller's deadline already bounds every call, so a second timer that
  Gun owns adds no protection and overrides a decision that belongs to the
  caller. Choosing a larger finite value would only move the cut.
- Gun also enters its closing state when its owner, the pool, exits. Without
  the closing timer, a connection with an active stream would then stay open
  until the peer ended the stream. The body owner already monitors its client
  and settles the call when the client exits; closing the connection at that
  point removes the only path on which a connection could outlive its client.
  An early H1 release already closes the connection, and an H2 cancellation
  resets the stream, so no other path keeps an unwanted stream open.

## Evidence

- `test/http_gun_stream_test.gleam`
  (`connection_close_response_streams_past_fifteen_seconds_test`) receives a
  17-chunk body sent one chunk per second after a `connection: close` head.
  Before the change it failed after 15 seconds with
  `RequestFailed(PeerClosed)` and MaybeSent.
- `test/http_gun_stream_test.gleam`
  (`supervisor_shutdown_closes_connection_with_open_stream_test`) shuts down
  the supervisor of a client with an open stream and observes the server's
  socket close within two seconds. Before the change the connection stayed
  open.
