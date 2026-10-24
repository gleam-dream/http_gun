# Record release decisions in ADRs and keep no changelog before the first release

<a id="adr-0015"></a>

## Decision

- Keep no changelog while the package is unreleased. The design layer states current guarantees and these ADRs retain the decisions that shaped them.
- Leave the package version unchanged until the owner decides on a release. Before then, breaking API and schema cleanup is authorized and owned tests and examples change together.
- Add a changelog at the first release. It lists `error.Reason`, `error.TransportCause`, `error.LimitKind` and `error.RequestProblem` variants added in each minor release under a **New variants** heading, because those types are open to growth.

## Rationale and alternatives

- A pre-release changelog duplicated ADRs and the design. Its "unreleased" list recorded construction milestones and one cleanup claim, a stronger abort guarantee than the implementation establishes, which ADR 0010 withdraws.
- A second narrative of the same decisions drifts. One home for rationale keeps a later reader from reconciling two accounts.

## Evidence

- Decisions the former list carried live in these records: additive cancellation (ADR 0012), the Cowlib 2.21 minimum (ADR 0007), per-client certificate identities and the TLS Certificate Required alert (ADR 0011) and conservative submission evidence with Sinal observations (ADRs 0006 and 0008).
