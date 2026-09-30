# Provenance and recovery

This is a fresh Gleam implementation, not a translation of the previous Erlang orchestration. No old production runtime was retained.

The initial checkout was clean at `6b0ab3f`, with empty source/test directories. Recovery copies are local and ignored by Git:

- `.archive/checkout-before-restart.tar.gz`: entire previous checkout and Git objects/build cache, excluding `.direnv`; SHA256 `eeb5848eb81f30314ce6d18549a90f3607e592454853a39421c17c41e55cee89`.
- `.archive/previous-implementation-a1ad984.tar.gz`: recovered previous source at `a1ad984a9249389988bbc936a9af71002419fe79`; SHA256 `66fb4e32a6e68e8b649d51e42a402e33d9418b5f073b582414e2102b79ea22df`.

Restore into a separate directory with `tar -xzf`, not over this implementation. The archived checkout retains recoverable Git history. Both copies were made before replacement.

Before the wave9 pool correction, the current Gleam source, tests and package manifests were preserved in `.archive/before-pool-fix-20260930.tar.gz`, SHA256 `43ef449ff60443c2c470dd413cb0d75a7f9f97f4fdf046520c8a61da21cc7a12`. The correction uses no new donor source or dependency.

Reviewed retention: Apache-2.0 LICENSE, the dependency manifest/package metadata, loopback H1/H2 servers and test certificates. [provenance.json](provenance.json) records each original revision and SHA256 before reuse. The H1 server gained an observable connection identity; other new test helpers are test-only. Existing pinned Nix tooling was retained. Old production code was not a donor.

Scoped design references:

| Reference | Revision | Use |
| --- | --- | --- |
| Dream HTTP client, PR68 | `c3ae1d341b0782aa89279151cf9afd6b7731b46e` | buffered/streaming usability, empty-response scenario |
| ReqCassette | `cb0251ca394952de46007bb32f5051feb66e896e` | sequential recording/playback scenarios |
| Gleam HTTPc | `0f5f2fdc88d58740e8790991e7b18529ead7d85a` | small standard-HTTP interface |
| Gun | released 2.6.0 | supported API, flow, settings notifications, TLS negotiation |
| Cowlib | released 2.20.0 | Gun's released protocol dependency |

These original references supplied scenarios and API constraints, not copied production implementation or a parity requirement. Package versions and checksums are in `manifest.toml`; Nix inputs are pinned in `flake.lock`. Gun/Cowlib source is unmodified. No dependency parser hardening was performed. The separately requested Dream comparison below records its own exact suite results.

The isolated LLM consumer uses a reviewed development-only source archive, `test/oracle/llm-consumer-source.tar.gz`. [consumer-source.json](../test/oracle/consumer-source.json) records the Git revisions, clean/dirty state and every retained file hash before archiving LLM Wire, json_blueprint and sinal. The archive preserves available LICENSE files (LLM Wire and sinal); json_blueprint's original manifest declares MIT and its inspected checkout has no LICENSE file. This local test snapshot is not a production dependency or a publication bundle. The gate verifies every recorded hash before compilation and never modifies a sibling checkout.

The adapted public-only LLM example's previous source revision/hash and Apache-2.0 attribution are in [consumer-example-source.json](../test/oracle/consumer-example-source.json). Provider encoding, status interpretation and reduction remain in that separate consumer. New HTTP Gun production code has no LLM imports.

Wave7 adopted released file_streams 1.7.0 (MIT), simplifile 2.7.0 (Apache-2.0) and transitive filepath 1.1.2 (Apache-2.0). Their packages retain their license files; no source was copied into HTTP Gun. [Filesystem review](FILESYSTEM.md) records the integration choice and [archive/source hashes](filesystem-review.json) identify reviewed releases. The manifest pins exact adopted versions and Hex checksums.

Wave8 tested the requested Dream `codex/http-client-combined` branch at `bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5`. Its downloaded archive SHA256 is `d518ec13f566dd8d60482eef0076fa562625fed4f1f2ffcbb38c4cbc1d8735fd`. [Pre-use module hashes](evidence/dream-comparison/source.json) and the isolated archive preserve the MIT license and original source. Only two stale local dependency versions in its development lock were reconciled; no upstream source was changed or copied into HTTP Gun. The [comparison report](DREAM_COMPARISON.md) distinguishes original check failures, the 213-test successful reconciled suite, and measurements using a common comparison lock. The test harness reuses this package's already reviewed local servers and certificates; it adds no production dependency.
