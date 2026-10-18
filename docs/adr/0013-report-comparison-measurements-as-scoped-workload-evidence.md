# Retain oracle references and benchmark results as linked documents with scoped claims

<a id="adr-0013"></a>

## Decision

- Keep `docs/ORACLE.md` and `docs/BENCHMARKS.md` as retained reference documents. The oracle document pins each external reference, says what is compared and how outcomes are classified, and states exclusions and limits. The benchmark document holds the method, the run commands and the dated results.
- The two documents link each other, the design's validation section and the decision records. `AGENTS.md` and the README link both, so an agent changing a reference or a measurement finds them.
- Retain the HTTP Gun and Dream comparison as a runnable harness with a behavior contract suite and a separate timing run. Report each timing with its workload, runtime, hardware and source hashes.
- State no performance ranking, latency promise or allocation guarantee from these measurements. Rerunning the harness produces new evidence for the current source and never reproduces retained hashes automatically.
- Keep raw receipts under `docs/evidence` as non-markdown data. The design states the method rules and never a result.

## Rationale and alternatives

- An earlier decision kept result tables out of living documentation, because a table in a README reads as a standing claim. Dropping the results also dropped the pins and the method that make an observation checkable. A dedicated, dated document with its limits next to the table keeps the evidence findable without making it a promise.
- Three local H1 trials on one machine establish scheduling behavior under that workload only. The document therefore carries the environment, the date and the statement that the run predates the current checkout.
- Comparing wall time without matching application concurrency misattributes pool semantics. The four-worker case gives both clients the same concurrency, and Dream's persistent-session setting is reported as a different connection model.
- Sampling whole-VM memory, mailboxes, processes and ports every 10 ms includes local servers, callers and the sampler and misses short peaks. The numbers bound nothing inside Gun or Cowlib.
- Putting method and pins in an ADR alone would freeze them. The documents are updated when a reference or a rerun changes, and an ADR records only the decision about how they are kept.

## Evidence

- The retained run accompanies the 2026-09-30 scheduling correction in ADR 0003. Environment, results, the failed Dream trial and the Dream pin are in `docs/BENCHMARKS.md`.
- Pins, comparison cases and classification rules are in `docs/ORACLE.md`. The Cowlib 2.21 source audit that qualified the native range is summarized there and in ADR 0007, with its source inventory and receipt in `docs/evidence/cowlib-2.21`; the qualification archive is retained in Git history at `6f9f8cc`.
- Receipts: `docs/evidence/comparison` (inputs, raw measurements, summary, failed-trial observation) and `docs/evidence/dream-comparison/source.json`.
