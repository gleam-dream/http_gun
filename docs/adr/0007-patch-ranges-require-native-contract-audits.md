# Patch ranges require native contract audits before widening

<a id="adr-0007"></a>

## Decision

- Depend on Gun `>= 2.6.0 and < 2.7.0` and Cowlib `>= 2.21.0 and < 2.22.0`. Qualify the committed minimum and the newest admitted patch in CI.
- Re-audit the undocumented native assumptions before widening to another minor release or before relying on additional message, info or error fields. The design's native assumption inventory lists each assumption with its source and its behavior if it changes.
- Raise the Cowlib minimum to 2.21.0 because 2.21.0 fixes CVE-2026-43969, an injection flaw in the request-cookie encoder. Exclude 2.22.0 until its own audit.

## Rationale and alternatives

- Exact pins block consumer security-patch uptake. Unrestricted minor ranges permit unreviewed changes to terms the manuals do not contract.
- A missing H1 `state_name: connected` must refuse reuse. Unknown native error terms map to UnknownTransport. Neither case upgrades evidence or resends requests.
- Test-only Cowlib framing and HPACK modules are also undocumented. Their incompatibility can invalidate H2 evidence even when production calls still compile.
- HTTP Gun configures no Gun cookie store and keeps Gun's `invalid_request_headers=raise` default, so the cookie-encoder flaw is not reachable through an HTTP Gun API. The minimum still moves, because a downstream application can reach the encoder through the shared dependency.
- CVE-2026-43966 (structured-field encoding) is not declared fixed by 2.21.0, because Cowlib's structured-field encoder is unchanged. HTTP Gun calls neither structured-field encoding nor cookie-store configuration.

## Evidence

- The first audit was recorded on 2026-10-02 against Gun 2.6.0 and Cowlib 2.20.0. `c55934a` records the minimum and latest-patch CI; `e55fa1d` records the release range selection.
- The 2026-10-11 Cowlib 2.21 audit compared the two Hex archives, whose SHA-256 values match the release metadata on hex.pm. The exported functions of `cow_http2`, `cow_http2_machine`, `cow_hpack`, `cow_http_te` and `cow_cookie` are unchanged, and `cow_hpack.erl` is byte-identical.
- Every upgrade-sensitive assumption survived: Gun's `info/1`, error conversion, `terminate/3` event callback, asynchronous request submission and SETTINGS handling are unchanged. The H2 changes concern HPACK initialization, reset-stream header draining, push-promise validation and padded PUSH_PROMISE parsing; the test fixture's settings, headers, data, ping, reset and GOAWAY shapes remain.
- A direct `cow_cookie:cookie/1` probe preserves binary and iodata controls in both releases. Version 2.20.0 rejects zero of six invalid inputs and 2.21.0 rejects all six, including CRLF and semicolon injection. The probe checks the encoder, not an HTTP Gun cookie API.
- The full gate passes on OTP 27, 28 and 29. Each run passes 212 root tests, 212 tests at each stdlib boundary (0.71.0 and 1.0.5), the ordinary, async and mTLS consumers, twelve compiler refusals, seven nghttpd scenarios, batch and recording checks and all eleven load scenarios. All eight retained manifests select the expected native versions.
- The selected LLM Wire consumer (`14152fa`) passes its 402 tests, public-boundary checks and five local H2 scenarios up to 1,000 simultaneous calls over one connection. Resolution first fails on its old lockfiles; updating only their Cowlib rows resolves both failures and changes no Wire source.
- Raw receipts, the source inventory, the compressed source diff and the qualification archive (with its per-run logs, including the rejection-failure logs) sit under `docs/evidence/cowlib-2.21`. The encoder probe (`cookie_probe.escript`) and its two per-release outputs (`cookie-2.20.0.log`, `cookie-2.21.0.log`) are retained in Git history at `326296d`, under the same directory. These results do not claim execution of remote CI or the extended weekly workflow.
- Consumers pinned to Cowlib 2.20.0 run `gleam update cowlib` in each affected package, separately locked examples included, and rerun their own gates. Updating a shared path dependency does not update those lockfiles.
- The pinned archives and the other external references are listed in [ORACLE.md](../ORACLE.md).
- Implementation: `gleam.toml`, `manifest.toml`, `.github/workflows/check.yml`, `dev/boundaries.py`, `src/http_gun_ffi.erl`, `test/http_gun_h2_server.erl`.
