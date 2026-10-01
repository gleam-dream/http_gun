# Sinal adoption and regression evidence

The owner authorized generic Sinal fixes after selecting it for HTTP Gun's observation delivery. Canonical Sinal baseline: `098a2d5df70ed7dfff71151a865e986fb44987eb`. HTTP Gun baseline: `ebf2b479761e8c932b0c85a8f83cf8460c014d4f`. Working-tree changes are reported separately from those commits; no commit or publication was performed.

## Red, green and refactoring

Wave22 retains the first two synchronized regressions: startup before initialization completed, and a producer paused after reserving capacity but before sending across a restart. Each failed on the original source for its capacity/mailbox assertion. Fresh incarnation-owned counters and a direct subject corrected both.

Review exposed the same destination race for coalesced drop notifications. [sinal-drop-red.log](sinal-drop-red.log) shows the replacement mailbox growing0→1 when an old notification resumes. The final correction couples its one pending-notice flag with that incarnation's direct subject. All three final probes pass with mailbox0→0 for both stale send cases. [sinal-final.patch](sinal-final.patch) contains the complete generic change, including the regression runner and CI step. It adds no HTTP-specific behavior or public Sinal function. The final forwarder FFI is114 lines/4135 bytes, down from118/4610, with two ETS primitives replacing the named-send exception helper. The full Sinal handwritten FFI is304 lines/10196 bytes; HTTP Gun remains92/4669 through13 bindings.

The production source contains no synchronization hooks. Sinal's `dev/check_forwarder.py` instruments only disposable copies. The third probe initially exposed a syntax error in the disposable insertion for a single-expression branch; a wrapper fixed the harness before the recorded final gates. The earlier startup/capacity fix was not relabeled as sufficient without checking diagnostics.

[sinal-receipt.json](sinal-receipt.json) records final selected hashes and commands. On Darwin ARM64/Gleam1.18.1, all93 tests, format/check/build, handwritten Erlang `-Werror`, and three probes pass on OTP29/ERTS17.1, OTP28/ERTS16.4.0.6 and OTP27/ERTS15.2.7.13. Exact logs are adjacent. `validate-sinal.py --source /path/to/sinal` runs those checks in a temporary build tree under the selected toolchain.

HTTP Gun's initial public API test failed before the new module/configuration/correlation function existed ([red](http-telemetry-red.log)). The retained integration suite then passes98 tests ([fast](fast.log)). It checks scripts, real local Gun return before headers, queued deadline before grant, recording and strict playback, capture failure, dead/throwing observers and real H2 cancellation preserving a sibling on one connection.

The decisive ingress test blocks a capacity1 forwarder's handler, then requires1000 scripted requests in a bounded16-worker batch to finish before releasing it. Its mailbox contains one coalesced drop notice; at least3999 lifecycle observations are rejected. The positive control succeeds. `observer-control.py` changes only the emission call to synchronous Sinal delivery in a disposable source copy; that same test then fails waiting for the HTTP batch. Both [logs](observer-control/) are retained. Reproduce inside the pinned shell with `python3 docs/evidence/wave23/observer-control.py --root "$PWD" --output /private/tmp/new-observer-control`.

The public ordinary consumer includes a supervised Sinal forwarder and typed completion observation. Ordinary, maintained async and archived LLM consumers pass, with one positive compiler control and seven intended type restrictions. Final full-gate/downstream qualification is in wave24; these earlier fast/consumer logs are not presented as its replacement.

## Scope

One canonical Sinal implementation is used. Independent gates unpack its verified source archive adjacent to HTTP Gun in their temporary workspace; current downstream validation uses the actual selected canonical checkout. Historical donor source is verified before its old Sinal is replaced. No source is combined or mechanically translated. LICENSE and source hashes are preserved in `dev/dependencies`.

HTTP Gun adds typed facts at existing ownership points, not a collector, timeline, second body server or custom observation FFI. Observation is best effort and never evidence of remote receipt. Capture/persistence failures remain separate. User exporters own any queues beyond Sinal. No Gun/Cowlib changes, provider traffic, sibling LLM Wire edits, commits, pushes, publication or hosted CI execution occurred.
