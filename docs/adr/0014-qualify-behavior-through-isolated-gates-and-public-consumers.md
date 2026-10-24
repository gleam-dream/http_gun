# Qualify behavior through isolated gates and separate public consumers

<a id="adr-0014"></a>

## Decision

- Run every normal gate in an isolated copy that consumes no sibling working copy. Keep downstream qualification an explicit, separately selected command that records the tested source identity.
- Qualify public contracts through separate packages that import only public modules: the ordinary, async and mutual TLS consumers.
- Keep usage documentation as compiled, runnable examples in those consumers, one module per topic, instead of a prose guide. The README keeps a short mirror whose snippets `test/http_gun_readme_test.gleam` compiles in the fast gate, and the full gate builds and runs the consumers, so API drift fails a gate.
- Run six full-gate CI lanes (OTP 27, 28 and 29, each with the committed minimum and the newest admitted Gun/Cowlib patch) plus a separate design job. Run the soak, native ARM64 qualification and the public comparison harness in a weekly or manual extended workflow.
- Retain each run's evidence in a directory that the next run replaces, so a failed run cannot export an earlier success.

## Rationale and alternatives

- A gate that reads sibling checkouts passes or fails by their state and can modify them. Isolation keeps results reproducible and keeps other tasks' checkouts untouched.
- Passing package tests establish their named observations. Source compatibility alone does not establish chunked-response, trailer or H2 behavior, so real local peers (an Erlang H2 server and nghttpd) are required evidence.
- A consumer compiled as its own package catches accidental reliance on internal modules and opaque-capability construction, which in-package tests cannot.
- A prose usage guide drifts from the API unnoticed. A compiled example fails the gate when a name, a type or a behavior it shows changes, so the examples are the usage reference.
- Running the extended workflow outside required CI keeps the push gate bounded while the soak and platform evidence still has an owner and a retention period.
- Archived consumers prove only their recorded revisions. Requiring a fresh, explicitly selected downstream run avoids carrying an old result forward as a current claim.

## Evidence

- Gate implementation: `dev/gate`, `dev/isolated_gate.py`, `dev/matrix`, `dev/linux-gate`, `dev/check_results.py`, `dev/check_native.py`, `dev/check_downstream.py`, `.github/workflows/check.yml` and `.github/workflows/qualification.yml`.
- The result checker rejects missing, empty, failed, skipped or ambiguous summaries and requires all eleven load workloads. Its controls and the gate's timeout control are exercised by `dev/test_gate.py`.
- The batch scaling guard `5000 requests < 15 × 500-request median + 50 ms` was established with ADR 0003's scheduling correction. It adds no absolute latency promise.
