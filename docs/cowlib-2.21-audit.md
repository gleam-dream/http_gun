# Cowlib 2.21 qualification

## Scope and governing contract

CVE-2026-43969 affects Cowlib's request-cookie encoder before 2.21.0.
HTTP Gun's former minor ceiling excluded that released fix. ADR 0007 and
`design.typ` → Foreign boundary and dependency upgrades require a native source
audit and minimum/latest full gates before admitting another minor. This change
raises the minimum to 2.21.0 and excludes 2.22.0. Gun remains at 2.6.x.
No public HTTP Gun API, retry policy or dependency source is changed.

Qualification must preserve the existing public H1/H2/TLS, ownership, consumer,
error-evidence and capacity contracts. The canonical commands are
`./dev/env sh dev/gate full` and
`HTTP_GUN_DEPENDENCIES=latest ./dev/env sh dev/gate full`; the runtime matrix is
`sh dev/matrix`. Native design rendering, context export and design checking
remain separate. Current downstream qualification selects LLM Wire explicitly
through `dev/check_downstream.py`. Provider credentials are unnecessary.

## Source audit · 2026-10-11

The two Hex archives were downloaded from `repo.hex.pm`, and their SHA-256 values
match their exact release metadata at `hex.pm/api/packages/cowlib/releases/`.
[The retained source inventory](history/evidence/cowlib-2.21/sources.json)
identifies every archive file; the complete compressed source diff and encoder probe sit
beside it. The exported function lists of `cow_http2`, `cow_http2_machine`,
`cow_hpack`, `cow_http_te` and `cow_cookie` are unchanged.

| Upgrade-sensitive assumption       | Inspection result                                                                                                                                                                                                                         |
| ---------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| H1 `gun:info/1` state and protocol | Gun 2.6.0 is unchanged; `info/1` retains `state_name` and protocol. Unknown state still refuses reuse.                                                                                                                                    |
| Native error terms                 | Cowlib H2 errors retain `{connection_error, Reason, Detail}` and `{stream_error, Id, Reason, Detail}`. Gun's conversion is unchanged; native detail remains private.                                                                      |
| Terminal event before Gun exits    | Gun's unchanged `terminate/3` calls the configured event handler. No Cowlib callback changes this boundary.                                                                                                                               |
| Asynchronous request submission    | Gun still validates, casts to the connection and returns the stream reference. HTTP Gun continues to classify invocation as potentially sent.                                                                                             |
| H2 header counting                 | `cow_hpack.erl` is byte-identical; its bound counts decoded fields including `:status`. HTTP Gun retains the extra pseudo-header allowance.                                                                                               |
| SETTINGS and capacity              | Gun's unchanged SETTINGS handler reads `get_remote_settings/1`; Cowlib's settings processing and this accessor are unchanged. H2 internal changes concern HPACK initialization, reset-stream header draining and push-promise validation. |
| H2 test framing and HPACK          | Framing exports are unchanged; the parser fixes padded PUSH_PROMISE. The fixture's settings, headers, data, ping, reset and GOAWAY shapes remain. HPACK implementation is byte-identical. Runtime gates still have to qualify them.       |

Other upstream changes tighten cookies and dates, fix incomplete chunked
response handling, and correct WebSocket fragmentation/close handling. HTTP Gun
owns HTTP exchanges and does not expose a WebSocket or cookie-store API. Its
full gate exercises chunked response/trailer delivery and H2 behavior through
real local peers; source compatibility alone is insufficient acceptance.

## Security evidence and limits

The same direct `cow_cookie:cookie/1` probe preserves binary and iodata controls
in both releases. Version 2.20.0 rejects zero of six invalid inputs; 2.21.0
rejects all six, including CRLF and semicolon injection. This checks the
underlying encoder, not an HTTP Gun cookie API or a demonstrated application
exploit. The [EEF advisory](https://cna.erlef.org/cves/CVE-2026-43969.html) gives
the vulnerability's conditions and fixed range.

HTTP Gun does not configure Gun's optional cookie store; `undefined` bypasses
cookie encoding. It also leaves Gun's `invalid_request_headers=raise` default
intact. The separate structured-field advisory
[CVE-2026-43966](https://cna.erlef.org/cves/CVE-2026-43966.html) is not declared
fixed by this update: Cowlib's structured-field encoder is unchanged. The
advisory describes Gun 2.4+ header validation as a mitigation. HTTP Gun calls
neither structured-field encoding nor cookie-store configuration.

## Acceptance evidence

The full gate passes on OTP 27, 28 and 29. Both minimum and newest-admitted
selection run on OTP 29 and resolve the same Gun 2.6.0/Cowlib 2.21.0 versions.
The OTP 27/28 runs use that committed minimum. Each full run passes 212 root
package tests, another 212 tests at each stdlib boundary (0.71.0 and 1.0.5),
ordinary/async/mTLS consumers, twelve compiler refusals, seven nghttpd scenarios,
batch/recording checks and all eleven load scenarios. All eight retained
manifests in each run select the expected native versions.

The selected Wire `14152fa` consumer passes 402 tests, its public-boundary
checks and five real local H2/concurrency scenarios, up to 1000 simultaneous
calls over one connection. The first attempt fails resolution on its old root
lockfile; after updating that lock, the separate consumer lock fails the same
way. Updating only those two Cowlib rows resolves both failures. No Wire
runtime, test or tooling source changes are needed, and every selected source
hash remains unchanged during the successful qualification.

The [qualification receipt](history/evidence/cowlib-2.21/qualification.json)
identifies runtimes, selected manifests and commands; its compressed evidence
archive retains raw logs, including both failed baselines. Rendering, context
estimation, the selected foreign-boundary section and native design checks pass.
Existing pending-ledger date guidelines remain; no unrelated ruling is cleared.
These local results do not claim execution of remote CI or the extended weekly
soak/platform/comparison workflow.

Consumers pinned to 2.20.0 must run `gleam update cowlib` in each affected
package, including separately locked examples, and rerun their own gates.
Updating a shared path dependency alone does not update those lockfiles.
