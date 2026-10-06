# HTTP Gun

Read docs/design/design.typ, docs/design/CONTEXT.typ, docs/COVERAGE.md and the relevant docs/adr record before changing this package. The design captures current contracts; ADRs retain rationale. Use progressive implementation for follow-up work and preserve accepted behavior. Retired construction plans and wave trackers are not current authority.

Implement public API, domain state, pool admission, body ownership, batching, matching, codecs and recording coordination in Gleam. Use pinned gleam_otp and gleam_erlang APIs. Handwritten Erlang is restricted to Gun bindings/message conversion, genuinely missing filesystem/runtime operations and exception-safe scope cleanup. No Erlang pool, body-owner or cassette-session servers.

Gun/Cowlib own wire protocols. Do not patch dependencies, implement parsers or pursue whole-stack memory certification. Document post-parse admission limits honestly. No retries, redirects or decompression. Generic HTTP bytes, statuses, duplicate headers and trailers are required.

Change only this repository unless the task names a sibling; /code/gleam-dream/oversight and sibling repositories are otherwise read-only. Push to master after the full gate passes and the change is validated against the packages and apps that use it. Hex publication, upstream contact and provider credentials need explicit owner approval. Never alter another task's checkout.

Use observable public tests, one failing scenario at a time, followed by minimal implementation and refactoring while green. Fast: ./dev/env sh dev/gate fast. Full: ./dev/env sh dev/gate full. Missing functionality is unfinished, not a passing limitation. Retain exact qualification evidence; do not claim completion of unexecuted workflows. Use docs/TESTING.md for current commands and docs/DEPENDENCY-UPGRADES.md before widening native dependency ranges.

Reuse file_streams and simplifile where their verified semantics preserve bounded reads, exclusive creation, atomic publication and cleanup. Keep custom filesystem FFI restricted to missing primitives. Body/query redaction is implemented. Crash-durable publication remains an optional owner decision; do not mislabel its absence as a Gun/Cowlib limitation. Inherited allocations and GOAWAY races require honest boundaries and correct supported-API use, not dependency patches.

This package is unreleased. Use the explicit isolated downstream gate in docs/TESTING.md when changing public contracts. ADR 0010 records downstream migration evidence; archived examples do not qualify a current consumer. Breaking API/schema cleanup is authorized; update owned tests/examples together. Do not add compatibility layers or migration-only variants for earlier experiments. Keep one strict, version-marked fixture schema; a format marker is not a package release.

Clients default to public destinations only. Local network tests/examples must explicitly set destination.allow_loopback; private-network use requires its own opt-in. Resolve and check the complete A/AAAA answer before opening each connection, then connect to that IP with original TLS identity. Never use SNI=disable for IP literals or bypass policy on connection replacement. DNS workers and admission remain in Gleam. Gun's unexposed status reason phrase is an explicitly accepted, documented parser boundary; do not patch the dependency to change it.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — GitHub issues in `gleam-dream/http_gun`, accessed with
`gh issue list --repo gleam-dream/http_gun` and `gh issue view NUMBER --repo gleam-dream/http_gun`.
Labels bind roles as follows: `needs-triage` → `needs-triage`,
`needs-info` → `question`, `ready-for-agent` → `ready-for-agent`,
`ready-for-human` → `ready-for-human`, `in-progress` → `in-progress`,
`done` → `done`, `wontfix` → `wontfix`, `bug` → `bug`,
and `enhancement` → `enhancement`.

**AI disclaimer** — AI-authored tracker comments start with
`AI-assisted contribution.`

**Design gate** — `nix run .#design-gate-check -- docs/design .` checks render freshness,
vocabulary references and layer integrity (exit 0 clean, 1 violation, 2 error).
The gate is supplied by the pinned `design-layer` flake input.
`nix run .#design-gate-render -- docs/design docs/design/design-layer.pdf`
rebuilds the rendered document. `nix run .#design-gate-context -- docs/design --estimate`
estimates agent context; the same command without `--estimate` emits ephemeral
Markdown. `--manifest`, `--preview`, and `--section PATH --expect-digest DIGEST`
support loading selected sections. A bare Typst compilation does not run the gate.

**Context verification** — use native semantic blocks for lists, tables,
models and behavior. After authoring, verify context estimation and a selected
section export as well as rendering and the design gate.
Run these commands sequentially for each layer; they share its generated
`.render` workspace.

**Staleness** — source changes since the design last changed require a
conformance review before the layer is treated as current.

<!-- agent-skills:end -->
