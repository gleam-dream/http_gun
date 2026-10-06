# Every live connection uses checked addresses and narrowing views

<a id="adr-0004"></a>

## Decision

- Default to public address admission. Loopback/private use is explicit; reserved and metadata addresses remain refused.
- Resolve and validate the complete address answer before opening Gun on one selected IP tuple. Preserve original HTTP authority and TLS identity. Recheck every new or replacement connection.
- Intersect startup and all view policies, including the checked answers of reused connections. A required view destination is satisfied only by selected hosts or a refused address class, never by a scheme-only restriction.

## Rationale and alternatives

- Authorizing only the original hostname would leave its resolved addresses unchecked. Checking only a selected answer would admit a mixed public/private result. Letting Gun resolve again would disconnect admission from the actual connection.
- Passing SNI disable for literals can weaken IP SAN verification. Omitting SNI preserves OTP's identity check on the connected IP.
- A shared client's union of tenant destinations is reachable by any caller holding the base handle. Requiring an actual narrowing destination exposes missing tenant selection rather than letting a library's HTTPS-only restriction satisfy it.
- DNS changes do not revoke an existing checked connection. Re-resolving on every reuse would add a separate lifetime policy and still would not make inspection atomic with use; authorization lasts for one connection.

## Evidence

- `b517725` (2026-10-01) records policy/DNS pinning; `369da4f` records trust/reuse corrections. `0bf369f` (2026-10-02) adds required views; `4a6eeb0` (2026-10-03) makes narrowing selection precise.
- `destination.gleam`, `internal/resolution.gleam`, `pool.gleam:admit_connection`, `http_gun_ffi.erl:open/9`, destination/trust/wire tests and external consumer view cases.
- Warden at `230c6bb4171a782d5b4f4f795bbdc108cad49964` was a read-only scenario input; no Warden source was copied. Receipts remain in `docs/history/evidence/wave28` and `wave31`.
