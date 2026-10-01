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

Wave11 retained LLM Wire's SSE framer only in the isolated consumer and adapted three provider fixture strings. [Pre-reuse SHA256 and revision](evidence/wave11/donor-source.json) identify source at bbde1d927675e3fe55dcbc5f456a9bcb6fe24107. The [Apache-2.0 license](../examples/llm/LICENSE.llm_wire) is included. No HTTP Gun production source imports LLM internals. Finch/Mint/Gun/ReqCassette supplied scenarios only, with [reviewed file hashes](evidence/adoption-review/reference-sources.json); no source from their suites was copied.

Wave12 adds nghttpd1.70.0 to development shells through existing flake.lock; production Hex dependencies are unchanged. [Official server options](https://nghttp2.org/documentation/nghttpd.1.html) informed verified-TLS, peer-capacity and trailer tests. The optional Linux gate uses official Nix ARM64 image ghcr.io/nixos/nix@sha256:7a007c766426c1877758ddc5cb87a965ac131fc78c582ce0083d922d51ae945c, containing Nix2.35.2. It copies a read-only source archive into a disposable container, with no sibling mounts or credentials.

API ergonomics waves13–16 start from local commit1f53017. No donor source or dependency change was introduced. Selected Gun/OTP error terms and pinned file_streams/simplifile error variants were inspected locally; new Gleam code and the narrow FFI classifier are package-owned. Handwritten production FFI is now92 physical lines/4669 bytes/13 declarations, with responsibilities recorded in API_ERGONOMICS.md. Earlier snapshots, licenses and reference hashes remain unchanged.

Wave17 removes compatibility for unreleased experimental fixtures under explicit owner direction. It adopts no dependency, donor source, FFI or package version change. Wave16 receipts remain historical; the single current schema and required observed limit sizes are qualified in wave17 evidence.


## Adoption ergonomics follow-up

The generic asynchronous example was reviewed and retained from our own disposable API investigation; source hashes before adaptation are in [wave19/donor-source.json](evidence/wave19/donor-source.json). Its loopback servers/certificates continue to come from this package's attributed test infrastructure. No new upstream HTTP implementation or provider logic was copied.

The explicit downstream driver executes selected LLM Wire, json_blueprint and sinal source only in isolated copies, preserving their manifests and license files. [Wave18](evidence/wave18/current-downstream/receipt.json) and [wave21](evidence/wave21/current-downstream/receipt.json) record revisions, source/lock hashes, commands and outcomes. The resolved-closure positive/negative compilation technique was also inspected in the migrated LLM Wire boundary script, whose exact source hash is included there. The archived example retains its existing provenance and remains historical evidence.

The observation-storage experiment remains in a temporary directory; only its logs, precise command, source hashes and selected dependency hashes are retained in [wave21/observation-receipt.json](evidence/wave21/observation-receipt.json). No experiment bridge, ETS dependency, Gun event handler or lifecycle-observation API was added to production. The production FFI remains92 lines/4669 bytes/13 declarations; the asynchronous example adds only a4-line test mailbox measurement.


## Sinal observation adoption (waves22–24)

The owner authorized generic corrections in Sinal, starting at `098a2d5df70ed7dfff71151a865e986fb44987eb`. Original and first candidate hashes/red-green logs are in [wave22](evidence/wave22/receipt.json); final selected source and its recorded dirty state are in [sinal.json](../dev/dependencies/sinal.json). The original Apache-2.0 LICENSE and package manifests are preserved. The source archive is a reproducible validation input for this unpublished dependency, not an independent fork. Source generation and verification are in [sinal_source.py](../dev/sinal_source.py); the [source arrangement](OBSERVATIONS.md#one-sinal-source) explains why canonical development, historical fixtures and isolated builds resolve one selected Sinal source.

The generic correction couples incarnation-owned direct destinations, admission counters and coalesced drop notices. Two narrow ETS primitives replace the need for exception-wrapped named sends in Sinal. All tests/instrumentation remain outside HTTP Gun production FFI. Gun/Cowlib source is unchanged. The previously archived LLM donor is still hash-verified before its old Sinal is removed and the selected snapshot installed in the disposable workspace. No sibling other than explicitly authorized Sinal is edited.


Local integration: the generic Sinal correction is committed as `8acec4507f23daa7f49c40cc7d39816a5a4c3d1d`. Its normal formatting hook removed one extra blank line from README.md; selected runtime source, manifests, tests and license are byte-identical to the validated source. The dependency snapshot was regenerated from that clean commit. [Integration recheck](evidence/local-integration-2026-10-01.json) records the two changed packaging hashes; the earlier qualification receipts retain their original inputs. No push or publication occurred.


Destination policy (waves25–28) uses Warden230c6bb4171a782d5b4f4f795bbdc108cad49964 as read-only behavioral evidence. Transport source SHA2560fd3b160ecb50575a7185b4927b7010c684a218a3ba4e8fc46471d3d1de568cc; tests SHA256f079d5ee5edc04b403d281c973a203080d3328cd7291a86d0e848d5c1c0f4c36, recorded before implementation and unchanged afterward. No Warden source was copied. New IP-SAN fixtures are generated locally by dev/ip-fixture; existing certificate/server attribution is retained. Gun2.6.0/Cowlib2.20.0 and Gleam OTP/Erlang1.3.0 sources were inspected and remain unmodified. The [receipt](evidence/wave28/receipt.json) records scope, source hashes, runtime checks and the separate downstream setup experiment.
