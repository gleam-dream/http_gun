# Gun and Cowlib dependency audit

Audited 2 October 2026 against Gun 2.6.0 and Cowlib 2.20.0, the newest
releases on Hex on that date. The question: can HTTP Gun accept patch releases
of both, and where does it rely on terms the Gun and Cowlib manuals do not
document?

**Decision (owner, wave 3):** depend on `gun >= 2.6.0 and < 2.7.0` and
`cowlib >= 2.20.0 and < 2.21.0`. A patch release of either may fix a security
issue, and an exact pin would stop every consumer from taking it. The range
stops before the next minor release because the terms below may change in a
minor release without notice. CI runs the full gate on the minimum versions
(the committed `manifest.toml`) and on the newest patch of both
(`HTTP_GUN_DEPENDENCIES=latest`).

## Documented API used

| Call or term | Where | Status |
| ------------ | ----- | ------ |
| `gun:open/3` with `retry`, `protocols`, `connect_timeout`, `domain_lookup_timeout`, `tls_handshake_timeout`, `tcp_opts`, `tls_opts`, `transport`, `http_opts` (`flow`, `max_headers`), `http2_opts` (`flow`, `notify_settings_changed`, `max_headers`, window sizes) | `http_gun_ffi:open/9` | documented in `gun(3)` |
| `gun:request/6` with `reply_to` and `flow` | `request/5` | documented |
| `gun:update_flow/3`, `gun:cancel/2`, `gun:close/1` | `credit/3`, `cancel/2`, `close/1` | documented |
| `gun_up`, `gun_response`, `gun_data`, `gun_trailers`, `gun_inform`, `gun_upgrade` messages | `decode/1` | documented message shapes |
| `{gun_notify, Pid, settings_changed, Settings}` and `max_concurrent_streams` | `decode/1` | documented with `notify_settings_changed` |
| `gun:info/1` key `protocol` (`http`) | `reusable/1` | documented |
| `{tls_alert, {Alert, _}}`, `{bad_cert, _}` | `cause/1` | OTP `ssl` terms, documented by OTP |

## Undocumented terms relied on

Each item names what would break and how HTTP Gun fails if a release changes
it. In every case the failure is closed: a request fails or a connection is
not reused, and no request is sent twice.

1. **`gun:info/1` key `state_name` with value `connected`** (`reusable/1`).
   Gun's manual lists the keys of `gun:info/1` without `state_name`; the 2.6.0
   source adds it. HTTP Gun reads it to check that an idle HTTP/1.1 connection
   is still connected before reusing it. If the key disappears, the check
   returns `false`, every idle HTTP/1.1 connection is discarded instead of
   reused, and each request opens a new connection: slower, still correct.
2. **Reason terms of `gun_error` and `gun_down`** (`cause/1`). The manual types
   them as `any()`. HTTP Gun maps `{stream_error, _, _}` and
   `{connection_error, _, _}` to `ProtocolError`,
   `{connection_error, limit_reached, _}` to `HeaderLimitReached`, `closing` to
   `PeerDraining`, `closed` and `normal` to `PeerClosed`, and unwraps
   `{shutdown, _}` and `{error, _}`. An unknown term maps to
   `UnknownTransport`, so a changed term loses detail, never evidence.
3. **Submission evidence** (`internal/pool.gleam`, `internal/owner.gleam`).
   `NotSent` is reported only for failures that happen before `gun:request/6`
   is called. After it, every failure is `MaybeSent`. This needs no Gun
   internals, except one reviewed fact: Gun 2.6 returns from `gun:request/6`
   before writing to the socket, so a failure right after the call may or may
   not have reached the server. `MaybeSent` covers both cases.
4. **HTTP/2 `max_headers` counts the `:status` pseudo-header.** HTTP Gun
   passes `header_count + 1` for HTTP/2. Reviewed in the 2.6.0 source; the
   manual does not say. A change makes the limit one header stricter or
   looser, and HTTP Gun's own post-parse header check still applies.
5. **Test only: Cowlib's `cow_http2` and `cow_hpack`** (`test/http_gun_h2_server.erl`,
   23 calls). These modules are not part of Cowlib's documented API. A change
   breaks the HTTP/2 test server, which the gate runs, so it cannot pass
   unnoticed.

## Re-audit before

- widening either range to a new minor release;
- relying on another `gun:info/1` key, message field or error term.

Check items 1 to 4 against the new source, run the full gate on both ends of
the range, and record the result here.
