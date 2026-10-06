# Client views own per-call policy and configuration remains opaque

<a id="adr-0002"></a>

## Decision

- Use one operation entry point each for send, open, scoped response and batch. Per-call choices are pure views over one shared client.
- Use opaque caller-built Config, Policy, Redaction and RecordOptions with value-first setters. Validate complete Config before startup.
- A view's timeout or deadline replaces the startup request timeout. With both supplied, the earlier applies. Separate connect, pool and idle bounds remain independent.
- Public timeout/deadline/wait inputs use Duration, converted to whole milliseconds with a sub-millisecond remainder rounded away from zero.

## Rationale and alternatives

- Public settings records force downstream consumers constructing every field to migrate whenever settings grow. Setters allow callers to choose only meaningful differences.
- Request-option twins duplicate each operation and complicate composition. Views carry cancellation, policy and correlation through every operation and permit a library to accept the caller's same handle.
- A hard startup request ceiling would prevent one shared client serving ordinary calls and explicitly longer LLM/SSE streams. Replacing the outer request bound preserves independent phase limits.
- Int milliseconds leave units implicit. Duration names time at the public boundary while retaining one internal precision.

## Evidence

- `e55fa1d` (2026-10-02) records the release facade redesign. `dcfbc07` (2026-10-03) records Duration adoption. `4a6eeb0` records correlation reading and narrowing-view selection.
- Current contracts: `src/http_gun.gleam`, `src/http_gun/config.gleam`, `internal/settings.gleam`, `internal/pool.gleam:effective_deadline`; external consumer: `examples/ordinary/src/http_gun_consumer.gleam`.
- Recorded owner decisions and alternatives came from oversight's release API HTTPGUN-R1–R10 and DECISIONS, plus local docs/DESIGN.md. Never-published request-option APIs and schema migration guides are retired; CHANGELOG retains the actual public-change history.
