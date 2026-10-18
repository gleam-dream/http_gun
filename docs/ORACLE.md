# Oracle references

HTTP Gun compares its behavior with external references only where a reference
exists. None of them defines HTTP Gun's contract. The design states that contract,
and a reference is evidence about it. Measurements taken against the same
references are in [BENCHMARKS.md](BENCHMARKS.md).

## References

| Reference                      | What it is                                                                                                       | Pin                                                                                                                                                                                                                             | Compared against                                                                                                                                                                           |
| ------------------------------ | ---------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| Dream `http_client`            | The Dream project's Gleam HTTP client, <https://github.com/lostbean/dream>, branch `codex/http-client-combined`. | Commit `bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5` (2026-09-23), archive SHA-256 `d518ec13f566dd8d60482eef0076fa562625fed4f1f2ffcbb38c4cbc1d8735fd`, module file hashes in `docs/history/evidence/dream-comparison/source.json`. | Public-API behavior over local servers: the `comparison_contract` cases.                                                                                                                   |
| Gun and Cowlib                 | The Erlang HTTP client and parser library underneath HTTP Gun.                                                   | Gun 2.6.x and Cowlib 2.21.x. Hex archive hashes and the full source inventory are in `docs/history/evidence/cowlib-2.21/sources.json`.                                                                                          | Source audit of every upgrade-sensitive assumption, then the full gate on the minimum and the newest admitted patch ([ADR 0007](adr/0007-patch-ranges-require-native-contract-audits.md)). |
| `nghttpd`                      | The HTTP/2 server from the development `nghttp2` package, used as a real peer.                                   | The `nghttp2` version of the locked `nixpkgs` input in `flake.lock`; `dev/nghttpd.py` records `nghttpd --version` with each run.                                                                                                | Peer-capacity, trailer and concurrency behavior over real HTTP/2.                                                                                                                          |
| Local Erlang H1/H2/TLS servers | Test servers in `test/`, driven by the gate.                                                                     | The repository source itself.                                                                                                                                                                                                   | Framing, TLS identity and fault cases that need a controllable peer.                                                                                                                       |

## What is compared and how outcomes are classified

- **Dream behavior contract.** `examples/comparison/src/comparison_contract.gleam` runs each case against HTTP Gun and Dream and prints one JSON line per client, case and observation. The cases are binary responses, status handling, duplicate headers, trailers, local TLS, early closure, owner exit, explicit Dream callback cancellation and disk record and playback. `comparison_adapter` keeps status, error and body differences and gives both clients one call shape.
- **No pass or fail verdict.** A contract run retains each client's observation next to the other's. A difference is a documented observation about the two designs and not a failure of either. A difference becomes a defect in HTTP Gun only when the design states the behavior HTTP Gun missed.
- **Gun and Cowlib audit.** Each upgrade-sensitive assumption in the design's native assumption inventory is classified as unchanged or changed by reading the two release archives, and then qualified by the runtime gates. A source reading alone never admits a version.
- **`nghttpd` scenarios.** `dev/nghttpd.py` runs seven scenarios and the gate fails on any unexpected result.

## Exclusions and deliberate differences

- Dream differs from HTTP Gun by design in persistent-session connection semantics, callback-driven cancellation and its record and playback format. The comparison reports these as differences and compares concurrency only where both clients are given the same application concurrency.
- HTTP Gun exposes no cookie store, WebSocket or structured-field API. The Cowlib advisories that concern those surfaces therefore bear on HTTP Gun only through the unchanged call sites the audit records.
- No provider, credential or public Internet endpoint is used by any reference.

## Run

From the repository root, inside `./dev/env`:

```sh
./dev/env python3 dev/sinal_source.py build/dream-comparison/sinal
./dev/env python3 dev/comparison/run.py contracts --output build/comparison-recheck
./dev/env python3 dev/nghttpd.py
```

- Extracting the Sinal snapshot needs a new destination. Use a new output directory to keep earlier receipts.
- The wrapper downloads the pinned Dream archive when it is absent and checks its recorded hashes. Dream source stays in its isolated checkout and is never modified.
- Cowlib and Gun selection is exercised by `./dev/env sh dev/gate full` and `HTTP_GUN_DEPENDENCIES=latest ./dev/env sh dev/gate full`.

## Limits of the claim

- A reference observation describes that reference at its pin. It does not establish how HTTP Gun compares with any other release.
- The contract cases are a chosen set, not a conformance suite for HTTP or for Dream.
- The Cowlib audit checks the encoder and parser paths HTTP Gun reaches. It does not establish an application exploit and does not clear advisories for APIs HTTP Gun does not call.
- Local interoperability establishes behavior against local peers and carries no provider semantics.

## Related

- Design verification: [Validation profiles and gates](design/design.typ#validation-profiles-and-gates) and [Foreign boundary and dependency upgrades](design/design.typ#foreign-boundary-and-dependency-upgrades).
- Records: [ADR 0007](adr/0007-patch-ranges-require-native-contract-audits.md), [ADR 0013](adr/0013-report-comparison-measurements-as-scoped-workload-evidence.md) and [ADR 0014](adr/0014-qualify-behavior-through-isolated-gates-and-public-consumers.md).
- Runnable harness: [examples/comparison](../examples/comparison/README.md). Raw receipts: `docs/history/evidence`.
