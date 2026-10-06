# Changelog

This package uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
`error.Reason`, `error.TransportCause`, `error.LimitKind` and `error.RequestProblem` may gain variants in a minor release. Each release lists those additions under **New variants**.

## Unreleased — initial release

- A supervised Gun client owns bounded connection admission, streamed body lifetimes, response collection and batches.
- Caller-built views select request budgets, cancellation, correlation and narrowing destination policy. Address checks preserve the original TLS authority through resolution and reuse.
- Cassettes provide bounded recording, redaction, atomic publication and deterministic offline playback through the same client boundary.
- Typed failures retain exchange progress and remote-effect uncertainty; Sinal observations remain application-controlled.

The [README](README.md) documents current usage. The [design layer](docs/design/design.typ) records current guarantees and unresolved limits. [ADRs](docs/adr/0001-gleam-owns-exchange-state.md) retain the pre-release decisions. In particular, [ADR 0010](docs/adr/0010-consolidate-design-and-expose-cleanup-gap.md) records the cleanup guarantee that the implementation does not yet establish; the earlier changelog's stronger abort claim is withdrawn.

The package version remains unchanged pending a release decision. Superseded intermediate APIs and construction milestones have been consolidated into the design and decision records.
