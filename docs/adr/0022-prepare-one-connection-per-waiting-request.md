<a id="adr-0022"></a>

# 0022: Prepare one connection per waiting request

Date: 2026-11-25
Status: Accepted

## Decision

- An origin may prepare as many new connections at once as it has waiting
  requests, within the per-origin and total connection limits: at most
  min(waiting requests, per-origin limit − connections of the origin) new
  preparations, counting those already in progress.
- When a lane head waits, the pool starts connections for the requests
  behind it that hold no preparation, oldest first. It never launches a
  request there: the lane head still takes the first connection that becomes
  ready, so no request overtakes an earlier one in its lane.
- A connection is not bound to the request that started it. A preparation
  that finishes after the last waiter left is closed, as before.
- The readiness probe before reusing an idle HTTP/1.1 connection is
  unchanged.
- This supersedes the rule that an origin prepares only one new connection
  while it already prepares one. ADR 0003's lane ordering is unchanged.

## Rationale and alternatives

- With one preparation per origin, a burst to a cold origin opened its
  connections one after another. Each request that could not share a busy
  connection waited for every earlier handshake, so the wait grew with the
  burst size times the handshake time.
- Binding each connection to the request that started it would let a later
  request launch before an earlier one whose handshake was slower, which
  breaks lane order. Leaving connections unbound keeps the order with no new
  state.
- Scanning the whole lane on every event would cost time per waiter, the
  cost ADR 0003 removed. Lanes count their requests, and the walk visits
  only requests that hold a preparation and the ones it prepares for.
- A preparation that fails still fails every request in its lane, as it did
  when it was the only one. Requests that share an origin usually share the
  cause (resolution, refusal, trust), and failing them together keeps one
  attempt per request without hidden retries.

## Evidence

- `test/http_gun_pool_test.gleam` (`cold_origin_prepares_connections_concurrently_test`)
  holds five requests on a resolver that waits, with a per-origin limit of
  three, and observes three preparations at once; before the change it
  observed one.
- `dev/http_gun_cold_start_benchmark.gleam` measures the effect against a
  local TLS server that delays each handshake. [BENCHMARKS.md](../BENCHMARKS.md)
  retains the dated numbers.
