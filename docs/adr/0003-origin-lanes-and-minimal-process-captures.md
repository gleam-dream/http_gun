# Origin lanes and minimal process captures preserve bounded scheduling

<a id="adr-0003"></a>

## Decision

- Store normalized origin with each pending request. Maintain indexed FIFO lanes and consistent membership/counts rather than rescanning every blocked request after each release.
- Stop at a blocked lane head and continue other lanes. Rotate lanes that progress. Remove expired/dead entries immediately, including entries behind a blocked head.
- Process-crossing callbacks capture only operation inputs and destinations. They do not capture unrelated pending work, retained results or body queues.

## Rationale and alternatives

- The original 1,000-caller burst repeatedly recomputed origins and checked requests that could not run. Controlled probes with the same connections and callers identified scheduling work rather than the native transport as the dominant avoidable cost.
- Caching host lowercasing alone reduced one cost but retained queue scans. Increasing connections altered resource policy without fixing the repeated work. Requiring applications to use batch would not correct independently arriving callers.
- Capturing the whole scheduler record in a worker can retain every pending input and completed result in that process. Binding the operation and destination before spawning preserves semantics with smaller ownership.

## Evidence

- `1f53017` (2026-09-30) records pool/batch scaling and streaming-adoption correction after baseline `04ef776`. The exact tracked acceptance date is 2026-09-30; benchmark values are workload evidence, not general latency promises.
- Current implementation: `internal/pending.gleam`, `pool.gleam:dispatch_group`, `batch.gleam:advance`, `recorder.gleam` writer dispatch and `owner.gleam` capture callbacks.
- Raw burst/comparison and adoption receipts under `docs/history/evidence` remain. This record replaces the causal decisions in BURST_DIAGNOSIS, BURST_FIX, ADOPTION_REVIEW and ADOPTION_VALIDATION. The retired reports' original text remains in Git.
