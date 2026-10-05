# Restart progress

Correlation follow-up (HTTPGUN-R8, correlation part), 2026-10-02.
`http_gun.with_correlation` takes the caller's `sinal/correlation.Correlation`,
written under `correlation` by `correlation.field()` and omitted when absent.
HTTP Gun's per-invocation identity is the opaque `telemetry.RequestId` under
`request_id`; `telemetry.new_id()` is removed. A native `:telemetry` handler
test pins both keys, omission, replacement and distinct request ids under one
correlation. The Sinal snapshot is refreshed to f9cca37. The full gate passes
with 137 tests, the ordinary, async and archived LLM consumers and seven
rejection probes. Routed emission is left to wave 3. App call sites are listed
in [the migration guide](migration-wave-2.md).

Warden feedback follow-up complete locally,2026-10-01 (waves29–31). G1's public
bound now admits stdlib1.x; the full gate qualifies both0.71.0 and1.0.5. G2 adds
in-memory DER trust anchors directly through OTP cacerts. G3's reproduced idle
TLS/Connection:close reuse failures are corrected before submission with bounded
Gleam readiness jobs and explicit H1 retirement. Checks reserve admission
capacity and retain the original deadline. A close after inspection remains a
race with conservative evidence and no replay. G4 preserves the available
header-limit cause; four ambiguous malformed/truncated cases remain coarse.

All three full Darwin ARM64 gates pass on Gleam1.18.1/OTP29,28,27, each with128
tests on both stdlib pins, external consumers, TLS/H2, recording/replay and load
checks. All111 frozen inputs match. The adapted isolated LLM Wire check passes
223 tests plus boundary/local H2 checks. Warden's unchanged transport suite is
17/19, its security probes9/9, fast suite124/126, boundary controls and consumer
8/8 pass. Its two remaining tables require finer failure classes and strict
reason-phrase rejection unavailable through Gun's public API. Warden adoption
and release are not claimed. Exact failures, retries and skipped subcase are in
[validation](VALIDATION.md) and [receipt](evidence/wave31/receipt.json).
FFI totals121 lines/5900 bytes/16 bindings; orchestration stays in Gleam. No
dependency patch, commit, push, publication or sibling write occurred.

Local integration: the owner subsequently requested committing these fixes.
All111 frozen executable/dependency inputs still match the completed gates.
The local commit containing this update retains the tests, exact evidence and
remaining Warden differences; the normal fast pre-commit gate remains enabled.
No push, publication or sibling change is included.

Destination-policy follow-up complete, 2026-10-01. The client now defaults to public addresses only, resolves/checks complete A/AAAA answers in bounded Gleam workers, and pins Gun to the checked IP while preserving TLS identity and HTTP authority. Explicit loopback/private permissions, exact host allowlists and injectable resolvers are public pure configuration. Refusals and DNS failures are typed NotSubmitted results. TCP/TLS send bounds, deadline/cancellation cleanup, IP SANs, caller-mailbox isolation and delivered-header validation are tested. The owner accepted Gun's unobservable reason-phrase limitation; close-delimited TLS ambiguity is documented.

Fast passes 120 tests. All three full Darwin ARM64 gates pass on Gleam1.18.1/OTP29,28,27, including external consumers, verified H1/TLS/H2, nghttpd, actual recording/replay and load scenarios. All106 frozen runtime inputs match. Unmodified LLM Wire still compiles but its local suite has175 passes/48 expected loopback-policy failures; an isolated test/example configuration adaptation passes all223 tests, boundary checks and local H2 through1000 callers. Its production source and sibling checkout remain unchanged. Warden is read-only behavioral evidence, not migrated or released. HTTP Gun FFI totals113 lines/5585 bytes/15 bindings. See [validation](VALIDATION.md), [receipt](evidence/wave28/receipt.json) and waves25–28 in the tracker. The owner subsequently authorized the local commit containing this update. No push, publication, provider credentials or sibling/oversight changes occurred. Linux/hosted CI and Warden's future adapter gate were not run.

Previous follow-up complete, 2026-10-01: lifecycle observation uses Sinal. HTTP Gun's existing pool/body actors emit typed facts through an application-supervised bounded forwarder; no HTTP Gun collector or retained timeline exists. The owner authorized generic Sinal corrections for three reproduced startup/restart races, with its public API unchanged. All three full HTTP gates pass on Darwin ARM64/OTP29/28/27 with 98 tests, three consumers, seven type restrictions and real TLS/H2/recording/load workflows. Sinal passes 93 tests plus three synchronized probes on each runtime. Current LLM Wire passes 223 tests, its public boundary and five local H2 scenarios, with source checkouts unchanged during the isolated check. The initial Hex rate-limit failures are retained alongside successful sequential reruns. No required work remains in waves22–24. HTTP Gun FFI stays 92 lines/4669 bytes/13 bindings. The owner subsequently authorized local commits: Sinal is committed as8acec45, and the HTTP Gun integration is recorded in the commit containing this update. No push or publication occurred. See [OBSERVATIONS.md](OBSERVATIONS.md), [VALIDATION.md](VALIDATION.md) and the [final receipt](evidence/wave24/receipt.json). Historical sections below retain their original source/runtime scope.

Previous follow-up complete: waves18–21 implement immutable request-ceiling inspection, fallible cancellation scopes, the maintained generic asynchronous consumer, current downstream validation and accurate adoption docs. Final full Darwin ARM64 gates pass on OTP29/28/27 with91 tests, three consumers and the startup-failure regression; actual LLM Wire passes223 tests and local TLS/H2 validation. All production inputs match that downstream receipt. The lifecycle-observation experiment is complete as an investigation; its production API was deferred at that acceptance and subsequently authorized in waves22–24. No required implementation remains in this approved follow-up. Exact evidence is in [VALIDATION.md](VALIDATION.md) and the [wave tracker](implementation/gleam-first/wave-tracker.md). Historical statements below about no consumers/pending migration describe their original wave only.

Preserved pre-restart checkout (including Git objects and ignored build artifacts, excluding .direnv) in .archive/checkout-before-restart.tar.gz, SHA256 eeb5848eb81f30314ce6d18549a90f3607e592454853a39421c17c41e55cee89.
Recovered old source commit a1ad984a9249389988bbc936a9af71002419fe79 into .archive/previous-implementation-a1ad984.tar.gz, SHA256 66fb4e32a6e68e8b649d51e42a402e33d9418b5f073b582414e2102b79ea22df. Current starting HEAD is 6b0ab3f; working tree was clean with empty src/test directories.

Retained only inspected dependency locks, license, loopback test servers and test certificates. Source hashes were recorded before reuse in provenance.json. No old production runtime retained.

Selected toolchain: Gleam 1.18.1, OTP 29 through flake.lock. Gun 2.6.0/Cowlib 2.20.0 verified against published Hex package pages on 2026-09-29. Gleam OTP/Erlang 1.3.0 source APIs inspected: typed actors, selectors, monitors and child specs. Standard process.call panics on death/timeout, so public operations use monitored Result-returning calls in Gleam.

API ergonomics waves13–16 and pre-release cleanup wave17 are complete. The four ergonomic capabilities remain: bounded recording finish, fallible scopes, per-request deadline/cancellation and typed diagnostics. The unreleased package has one strict fixture schema with no legacy decoder, migration-only error categories or optional observed limit sizes. No external consumer migration is pending. Fast86 tests and six full gates pass on ARM64 Darwin/Linux × OTP29/28/27, including both examples, six type rejections,1196 LLM split points, nghttpd, recording/replay, batch scaling and eleven load scenarios. Generated docs build. Exact current receipts and frozen hashes are in docs/evidence/wave17; earlier receipts remain historical.

Production orchestration is Gleam. Handwritten Erlang totals 92 physical lines / 4,669 bytes through13 declarations across the Gun/runtime and filesystem bridges. No production substitute or untranslated old Erlang runtime remains. The prior source archives were rehashed and remain recoverable. Sibling consumer checkouts retain their original HEAD and status; oversight was read-only.

The README, BOUNDS.md, provenance, progressive tracker and CI describe the accepted scope and inherited limits. No push, publication, upstream contact or provider credentials were used. The original restart and burst correction were committed locally as04ef776; adoption validation was committed as1f53017. The API ergonomics follow-up and pre-release cleanup are implemented and validated, and recorded together in the local commit containing this update. Future work follows the progressive tracker, not the superseded architecture.

Wave7 adopted released file_streams 1.7.0 and simplifile 2.7.0 while retaining stdlib0.71 and Gun2.6/Cowlib2.20. It moved bounded file IO, permissions and atomic publication into Gleam using those libraries, leaving an eight-line filesystem bridge. Normal file close failures are propagated. Real H1/H2 red-green regressions fixed the configured header-count mismatch through Gun’s supported setting. Documentation distinguishes inherited behavior from optional client-owned redaction and durable publication. Full OTP 29/28/27 gates passed with 50 tests, both consumers, four rejections and eleven load scenarios each; receipts are in docs/evidence/wave7.

Wave8 completed the requested Dream comparison at bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5. Dream's native suite passed 213 tests after two disclosed local lock corrections; its original formatting/lock failures are retained. HTTP Gun's fast gate passed 50 tests. A separate public consumer checked 15/16 client-specific contract cases and 54 repeated H1 workload runs without request failures. HTTP Gun was faster with four bounded workers, similar on large streams, and slower than Dream's median at 1,000 simultaneous callers. Connection-limit semantics differ. See DREAM_COMPARISON.md and docs/evidence/dream-comparison for exact configuration, ranges, sampled resources and reproduction. Production code, dependencies and the 72-line FFI remain unchanged; burst admission profiling is a client-owned follow-up, not an upstream repair project.

Wave9 completed that client-owned correction on 2026-09-30. The Gleam pool now caches origins, serves per-origin FIFO heads, rotates progressing origins, indexes waiting/body ownership and removes expired or dead callers immediately. Playback keeps one ordered session queue. Body cleanup callbacks capture only their destinations rather than the full pool state. No public API, dependency or production FFI changed. A pre-fix source/test snapshot remains in .archive; its hash is recorded in PROVENANCE.md.

Final fast and full OTP 29/28/27 gates each pass 57 tests; full runs also pass both consumers, four type rejections and all eleven load scenarios. All 31 comparative contract observations pass. HTTP Gun succeeds in all 27 repeated workloads: the 1,000-caller median is 45.333 ms (45.247–60.599), down from 705.991 ms with the same four connections. Pool admission checks fall from 993,648 to 2,997 in a separate profile. Dream succeeds in 26/27 reruns; one burst reports 48 connection timeouts, so the overall comparison exits 1 and that failure remains disclosed. See BURST_FIX.md for exact evidence, practical memory/mailbox/latency results and remaining boundaries. The performance repair is accepted; no required client functionality is deferred by it.

The authorized adoption follow-up closes waves10–12. Narrow process captures fix public batch scaling: 5000 requests fall from 2377.275 ms to 166.490 ms median in three local trials. The external LLM example now streams incrementally with early cancellation and real record/replay; 1196 provider text-fixture split points pass. Five additional reference-derived scenarios bring the fast suite to 62 tests.

All six final full gates pass on Darwin ARM64 and Linux ARM64 with OTP 29/28/27. They include independent nghttpd 1.70.0 TLS/H2/cancellation/multiplexing, public batch trials through 10,000 inputs,256 recorded/replayed binary exchanges totaling 8 MiB, both public consumers and the original eleven load scenarios. A separate 60-second nghttpd check completes 317,900 requests with no failures and empty final body/waiting counters. Exact outcomes, environment, retained tooling failures and final hashes are in docs/evidence/wave12/receipt.json and VALIDATION.md.

The client is suitable for controlled adoption; the text example does not constitute a full sibling LLM session-runtime migration. Tools/continuations, remaining budgets and complete retry evidence remain that integration's responsibility. Production dependencies and the 72-line FFI are unchanged. Hosted x86_64 CI is configured but unexecuted here. These follow-up changes are retained locally; no sibling or oversight edits, push or publication occurred.

Waves13–16 preserve default HTTP calls while adding finish_wait, try_with_response, request_options, Deadline and Token. Wave16 initially added legacy compatibility; wave17 removes it under the owner's explicit pre-release cleanup direction. Error constructors are current across all owned tests and examples. A final controlled cancellation test exposed a shared connecting socket retained after its last waiter cancelled; Gleam pool cleanup now releases it immediately and the regression passes. No dependency, production filesystem bridge, sibling or oversight changes. Public examples and generated docs describe ownership, three distinct timeout meanings and safe error descriptions. See API_ERGONOMICS.md. Optional body/query redaction, crash durability and full sibling LLM runtime migration remain separate.

Wave17 records the owner's confirmation that the package is unreleased with no external consumers. A single marker1 schema replaces the experimental1/2 decoder; OtherLimit and optional limit observations are removed. Invalid negative fixture budgets now fail before IO or JSON decoding. Genuine unknown transport/IO causes remain. An old test polling helper raced disk writes; it now uses bounded finish_wait. Red/green evidence and all six current full gates pass; no package version, dependency, FFI, sibling or oversight change. The owner authorized a local commit after acceptance; no push or publication is authorized.
