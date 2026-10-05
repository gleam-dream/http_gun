# Sinal admission correction — preparation and subsequent authorization

The evidence below records the initial prepared candidate. The owner subsequently authorized changes to Sinal: “You can apply fix or improve sinal. Use TDD, keep it simple and generic so all can benefit”. The correction was applied; review also reproduced and fixed the delayed drop-notice case. Final source hashes and runtime evidence are retained in wave23. The original receipt remains unchanged so its preparation-time claims are not confused with later execution.

## Original preparation record

Sinal source: `098a2d5df70ed7dfff71151a865e986fb44987eb`, unchanged and clean after testing. The candidate is in `/private/tmp/http-gun-sinal-bn2b5vph/sinal`; the complete retained change is [sinal-forwarder.patch](sinal-forwarder.patch). `git apply --check` passes against that revision. No sibling source was modified and no HTTP Gun production observation API was added.

Two synchronized probes fail on the original source and pass on the candidate:

| Scenario                                                                 | Original                                       | Candidate                                                                                |
| ------------------------------------------------------------------------ | ---------------------------------------------- | ---------------------------------------------------------------------------------------- |
| Startup paused before diagnostic reset; capacity1; first handler blocked | Two events accepted                            | Unpublished target returns unavailable; once ready, second event is rejected at capacity |
| Producer paused before send; actor killed/restarted; replacement filled  | Old reservation enters replacement mailbox:0→1 | Sender retains old direct destination: replacement mailbox0→0                            |

The candidate publishes one actor-owned ETS row coupling a direct subject with fresh admission counters. The table disappears on actor death. Diagnostic counters remain separate and explicitly best effort. No new public Sinal function, HTTP Gun queue, protocol change or dependency parser patch is introduced. Two narrow ETS primitives are added to Sinal's existing bridge; orchestration stays in Gleam.

Validation executed on Darwin ARM64 with Gleam1.18.1 and OTP29/28/27: format/check/build,93 tests, all handwritten Erlang warnings as errors, and both synchronized probes pass on each runtime. Exact versions, input hashes, commands, logs and skipped work are in [receipt.json](receipt.json). An early incomplete test copy omitted README.md; its missing-file failure was a harness error, corrected before the recorded candidate gates. The probes inject synchronization hooks only into disposable copies; the candidate production source contains none.

The candidate includes `dev/check_forwarder.py` and its two probe assets. From a toolchain shell, `python3 dev/check_forwarder.py` checks the candidate. Pass `--source /path/to/original/sinal --scenario startup` or `--scenario delayed_sender` to reproduce each original failure. Hook injection is checked and limited to the initializer and event-send path. The selected original checkout remains read-only.

Not executed: application of the patch to Sinal, HTTP Gun dependency/instrumentation integration, resulting HTTP fast/full/downstream gates, or Linux/hosted CI. Permission to apply the sibling correction remains pending because the earlier workspace instruction explicitly kept siblings read-only. This wave is not complete.
