# Warden feedback qualification

HTTP Gun starts at `b517725d998e4f1e25fef3e49e3cea27ad3a5241`.
The changed working source is identified by [executable input hashes](inputs.json),
the isolated consumer receipts, and the final receipt. No commit or publication
is part of this follow-up. Gun2.6.0/Cowlib2.20.0 remain unmodified.

## Reproduction

Run from the HTTP Gun root, using the checked-in toolchain:

```sh
./dev/env python3 dev/check_stdlib.py
./dev/env gleam run -m http_gun_trust_test
./dev/env gleam run -m http_gun_reuse_test
./dev/env gleam run -m http_gun_destination_wire_test
./dev/env sh dev/gate fast
./dev/env sh dev/matrix
./dev/env gleam docs build
```

The full gate includes the independent stdlib1.0.5 consumer and the entire fast
suite pinned to1.0.5 in a disposable copy, alongside the normal0.71 lock. It
also retains the public consumers, type controls, async lifecycle scenarios,
nghttpd TLS/H2/cancellation checks, recording and bounded batch/load scenarios.
The normal gate needs no Warden or LLM Wire checkout.

`check_warden.py` and `adapted_downstream.py` are explicit, one-off integration
drivers. They require the named sibling checkouts **read-only** and create all
builds/adaptations in temporary directories. Their evidence directories must
not already exist. Each receipt records original revisions, dirty state, file
hashes, commands, exit codes and post-run source checks. No provider endpoints
or provider credentials are used. These drivers do not claim to migrate either
consumer or substitute for a released dependency.

## Red/green chain

| Concern | Failure before correction | Qualification |
| --- | --- | --- |
| Stdlib compatibility | [Independent consumer cannot resolve1.0.5](../wave29/stdlib-red.log) | [Consumer and original120-test suite pass](../wave29/stdlib-green.log); final full gates exercise128 tests on both pins |
| In-memory trust | [Unknown Anchors constructor](../wave29/anchors-red.log) | [Verified TLS](../wave29/anchors-green.log), [wrong-name/untrusted/invalid-only controls](../wave29/anchors-controls.log) |
| Idle TLS reuse | [PeerClosed/MayHaveBeenSent100ms after acknowledged close](../wave30/idle-red.log) | [Fresh connection2, sequence1](../wave30/idle-green.log); [close-token/deadline tests](../wave30/close-and-deadline-green.log) |
| Close token policy | [Mixed-case request close fails in the complete suite](fast.log) | Fixed token retirement; final128-test gates |
| Admission ordering | [First full run fails eligible-origin ordering on stdlib1.0.5](full-first.log) | Checks reserve active capacity; unused readiness is reset each dispatch; [128 tests pass](../wave30/fairness-green.log) and final matrix |
| Header-limit evidence | [Body ignores Gun's structured connection event](header-event-red.log) | [Public HeaderLimitReached result](header-green.log), with strict codec roundtrip in the normal suite |

`wave30/close-red.log` is an initially passing probe despite its historical
filename; it is **not** evidence of a reproduced failure. The idle TLS case
above is the actual red. Compilation/setup failures are retained as well.

The first final matrix completed OTP29 and28, then hit Hex's API rate limit
while resolving the OTP27 stdlib consumer, after that runtime's128 tests had
passed. A concurrent downstream attempt passed `gleam check` but hit the same
limit at `gleam build`. See [OTP27 attempt](otp27-rate-limit.log) and
[downstream attempt](downstream-adapted/receipt.json). The sequential
[resume script](resume-validation.sh) reruns only these incomplete gates.

## Warden result and remaining differences

The [final isolated adapter](warden-final/adapter.patch) passes DER anchors
directly to `config.Anchors` and maps `HeaderLimitReached` to HeadersTooLarge.
It removes the temporary PEM workaround. Warden's transport tests themselves
are unchanged, and all original checkout inputs match afterward.

- All9 retained security probes pass. Peer close followed by100/1000/3000ms
  succeeds on connection2; two Connection:close requests use two connections;
  timed-out caller mailbox stays0; shutdown takes0ms in this sample.
- Unchanged transport suite:17 passed,2 failed. The separate per-case table
  exposes every row, rather than stopping at each table's first assertion.
- Fast suite including the retained probes:124 passed,2 failed, the same two
  transport tables. Public boundary:13 intended rejections plus valid positive
  control. Independent consumer:8 tests passed.
- The security probe could not bind `[::1]:443`; its live IPv6 default-port
  subcase was skipped. HTTP Gun's own authority formatting test covers443,
  without claiming a live privileged-port exchange.

Header count/size failures now preserve available precision. Truncated
fixed-length bodies and signed chunk sizes still map to PeerClosed; invalid
status and signed content length can crash Gun and retain UnknownTransport.
All four fail conservatively. No internal stack/string matching invents a more
specific public cause.

The other failing table contains the owner-accepted reason-phrase exception:
Gun accepts a mixed-LF head by treating the embedded LF/header text as discarded
reason text, then supplies a close-delimited response. This is broader than
saying every bare-LF response is rejected. Strict rejection through the public
Gun API is not claimed. Warden must explicitly reconcile these expectations
before its own adoption gate can pass; no assertion was weakened here.

The adapter already owns endpoint policy such as rejecting content encoding and
checking declared body sizes. The table distinguishes its result from a bare
HTTP Gun request. HTTP Gun does not add automatic decompression or provider
semantics. The readiness observation can race with a subsequent peer close;
submitted work is never replayed and retains conservative evidence.
