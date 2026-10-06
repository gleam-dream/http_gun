# Sinal delivery remains application-controlled and best effort

<a id="adr-0006"></a>

## Decision

- Use typed Sinal lifecycle events, caller correlation and independent per-invocation identity. Add no HTTP-specific collector or retained observation history.
- Current default emission is `sinal.emit`. Application routes control where handlers execute. A direct forwarder can isolate one client; Silent disables it. Private library clients carry labels so applications can filter them.
- Observation events never grant submission, retry, application-consumption or capture-publication authority.

## Rationale and alternatives

- A fixed-slot pull-inspection experiment would create another history API and retention owner inside HTTP Gun. Its measurements did not establish network event ordering or production integration. The owner selected Sinal instead.
- Requiring an explicit forwarder for all clients prevents application-wide observation defaults. Default routed emission provides those defaults but allows synchronous handlers when no route exists. Callers wanting bounded asynchronous delivery must install routes or supply a direct forwarder.
- Generic Sinal forwarder qualification found that admission counters, direct destination and coalesced drop-notice state must belong to one actor incarnation. Otherwise an old reserved send or notice can enter a replacement actor. Those generic fixes remain in Sinal; HTTP Gun adds no custom admission FFI.
- This default supersedes the earlier direct-only nonblocking observation text. Current source/module documentation explicitly records synchronous un-routed behavior; the layer must not claim handlers can never delay HTTP owners.

## Evidence

- `2b3656e` (2026-10-01) records Sinal adoption. `c45adfe` and `056536b` (2026-10-02) adopt caller correlation/builders. `e55fa1d` selects default emission; `1a5f5ef` adds labels and silence.
- `telemetry.gleam`, `internal/lifecycle.gleam`, `config.gleam`, telemetry tests and ordinary consumer route setup.
- Sinal source receipts, generic forwarder qualification and rejected fixed-slot experiment evidence remain under `docs/history/evidence/wave18`, `wave22`, `wave23` and `wave24`; `dev/dependencies` owns the reproducible validation archive. Exact historical source selection remains with receipts rather than a second design contract.
