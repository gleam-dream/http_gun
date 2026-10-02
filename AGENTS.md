# HTTP Gun — Gleam-first restart

The owner's 2026-09-29 restart prompt governs this package. Read docs/DESIGN.md, docs/PROGRESS.md and docs/implementation/gleam-first/wave-tracker.md. Use progressive implementation for follow-up work; preserve accepted behavior and record each tested wave. This supersedes the previous Erlang orchestration architecture, local plans and conflicting oversight requirements.

Implement public API, domain state, pool admission, body ownership, batching, matching, codecs and recording coordination in Gleam. Use pinned gleam_otp and gleam_erlang APIs. Handwritten Erlang is restricted to Gun bindings/message conversion, genuinely missing filesystem/runtime operations and exception-safe scope cleanup. No Erlang pool, body-owner or cassette-session servers.

Gun/Cowlib own wire protocols. Do not patch dependencies, implement parsers or pursue whole-stack memory certification. Document post-parse admission limits honestly. No retries, redirects or decompression. Generic HTTP bytes, statuses, duplicate headers and trailers are required.

Change only this repository unless the task names a sibling; /code/gleam-dream/oversight and sibling repositories are otherwise read-only. Push to master after the full gate passes. Hex publication, upstream contact and provider credentials need explicit owner approval. Local archives in .archive preserve the pre-restart implementation; do not remove them. Never alter another task's checkout.

Use observable public tests, one failing scenario at a time, followed by minimal implementation and refactoring while green. Fast: ./dev/env sh dev/gate fast. Full: ./dev/env sh dev/gate full. Missing functionality is unfinished, not a passing limitation. Update progress and exact evidence; do not claim completion of unexecuted workflows.

Reuse file_streams and simplifile where their verified semantics preserve bounded reads, exclusive creation, atomic publication and cleanup. Keep custom filesystem FFI restricted to missing primitives. Body/query redaction and crash-durable publication are optional HTTP Gun features; do not mislabel their absence as a Gun/Cowlib limitation. Inherited allocations and GOAWAY races require honest boundaries and correct supported-API use, not dependency patches.

This package is unreleased. LLM Wire is a migrated downstream consumer (1c0ad614); the archived example is historical evidence. Use the explicit isolated downstream gate when changing public contracts. Breaking API/schema cleanup is authorized; update owned tests/examples together. Do not add compatibility layers or migration-only variants for earlier experiments. Keep one strict, version-marked fixture schema; a format marker is not a package release.

Clients default to public destinations only. Local network tests/examples must explicitly set destination.allow_loopback; private-network use requires its own opt-in. Resolve and check the complete A/AAAA answer before opening each connection, then connect to that IP with original TLS identity. Never use SNI=disable for IP literals or bypass policy on connection replacement. DNS workers and admission remain in Gleam. Gun's unexposed status reason phrase is an explicitly accepted, documented parser boundary; do not patch the dependency to change it.
