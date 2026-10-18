# HTTP Gun

HTTP Gun is an Erlang/OTP HTTP client written in Gleam. Read `docs/design/design.typ`, `docs/design/CONTEXT.typ`, `docs/COVERAGE.md` and the relevant `docs/adr` record before changing this package. The design states current contracts; ADRs retain rationale.

## Commands

- Fast gate: `./dev/env sh dev/gate fast`.
- Full gate: `./dev/env sh dev/gate full`.
- Runtime matrix: `sh dev/matrix`.
- Separate public consumers: `./dev/env sh dev/consumers`, `./dev/env sh dev/async-consumer`, `./dev/env sh dev/mtls-consumer`.
- Downstream qualification is an explicit, isolated command, `dev/check_downstream.py`. Run it when a public contract changes, and inspect its arguments first.
- Dependency range changes follow the design's native assumption inventory.

## Constraints

- Implement public API, domain state, pool admission, body ownership, batching, matching, codecs and recording coordination in Gleam on pinned `gleam_otp` and `gleam_erlang` APIs. Handwritten Erlang is limited to Gun bindings and message conversion, missing filesystem or runtime operations and exception-safe scope cleanup. No Erlang pool, body-owner or cassette-session servers.
- Gun and Cowlib own wire protocols. Do not patch dependencies, implement parsers or pursue whole-stack memory certification. No retries, redirects or decompression. Reuse `file_streams` and `simplifile` where their semantics preserve bounded reads, exclusive creation, atomic publication and cleanup.
- Local network tests and examples set `destination.allow_loopback` explicitly. Never use `SNI=disable` for IP literals or bypass destination policy on connection replacement.
- Use observable public tests, one failing scenario at a time, then minimal implementation and refactoring while green. Missing functionality is unfinished. Retain exact qualification evidence and claim no unexecuted workflow.
- The package is unreleased. Breaking API and schema cleanup is authorized; update owned tests and examples together, add no compatibility layers and keep one strict, version-marked fixture schema.

## References

- `docs/ORACLE.md` pins the external references compared with HTTP Gun (the Dream client commit, the Gun and Cowlib archives, `nghttpd`), says what is compared and how outcomes are classified, and states the limits of each claim.
- `docs/BENCHMARKS.md` holds the comparison method, the run commands and the dated retained measurements. The two documents link each other, the design's validation section and ADRs 0007, 0013 and 0014.
- Usage lives as compiled examples in `examples/ordinary/src/usage_*.gleam` plus the consumers in `examples/`. The gate compiles and runs them, so change an example together with any public API it uses.

## Workflow

- Change only this repository unless the task names a sibling; sibling repositories are otherwise read-only, and another task's checkout is never altered.
- Push to main after the full gate passes and the change is validated against the packages and apps that use it.
- Hex publication, upstream contact and provider credentials need explicit owner approval.

<!-- agent-skills:begin -->
<!-- framework-commit: cab7c0590036edaa66d8430cc5016399a9fd2c71 origin: git@github.com:lostbean/skills.git -->

(machine-owned; do not edit inside this fence — re-run setup to refresh)

## Agent skills

**Design layer** — `docs/design/design.typ` describes the design,
`docs/design/CONTEXT.typ` defines its vocabulary, and `docs/adr/` records
decision rationale. The rendered document is `docs/design/design-layer.pdf`.
`docs/COVERAGE.md` maps repository parts to their design owners.

**Tracker** — local markdown under `issues/`: one directory per feature
(`issues/<feature-slug>/`), the PRD at `issues/<feature-slug>/PRD.md`, issue
files at `issues/<feature-slug>/issues/<NN>-<slug>.md` numbered from 01. Each
issue file carries two header lines near the top — `Status: <state>`,
`Category: <category>`. Conversation appends to the bottom
of the file under a `## Comments` heading. Labels (canonical strings, adopted
verbatim): states `needs-triage`, `needs-info`, `ready-for-agent`,
`ready-for-human`, `in-progress`, `done`, `wontfix`; categories `bug`,
`enhancement`.

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
