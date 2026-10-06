# Gleam owns exchange state and Gun owns wire protocols

<a id="adr-0001"></a>

## Decision

- Retain the owner's 2026-09-29 restart decision. Gleam owns client policy, admission, body state, batching, matching and recording coordination. Erlang binds Gun/OTP, exception scopes and missing filesystem primitives.
- Keep Gun/Cowlib as the wire implementation. Do not revive the previous Erlang orchestration, custom parser hardening or dependency patches.

## Rationale and alternatives

- Handwritten Erlang state servers would duplicate Gleam domain state and weaken the intended public ownership model. Reusing only a buffered HTTP wrapper would omit streamed-body ownership, H2 capacity and bounded live capture.
- A new wire parser would make this package responsible for protocol compatibility and allocation guarantees that the supported Gun event boundary does not provide. Narrow native bindings preserve one transport oracle while keeping policy testable in Gleam.
- The restart is evidenced in local AGENTS.md and docs/DESIGN.md. The original approval transcript is not retained as a tracked artifact; its recorded date is 2026-09-29. Commit `04ef776` on 2026-09-30 records the resulting client.

## Evidence and provenance

- Current authorities: `src/http_gun/internal/{pool,owner,recorder,pending,batch,script,codec}.gleam`; foreign bindings: `src/http_gun_ffi.erl`, `src/http_gun_file_ffi.erl`.
- Original restart recovery evidence lives in `.archive`; preserve it. Recorded snapshots were the pre-restart checkout and previous implementation at `a1ad984a9249389988bbc936a9af71002419fe79`. Their provenance hashes remain recoverable from Git history; this migration does not requalify their contents.
- `NOTICE`, test certificate attribution, `docs/history/evidence/adoption-review/reference-sources.json` and Dream comparison source receipts retain license and reference evidence. Dream, ReqCassette, Gleam HTTPc, Mint and Finch supply scoped scenarios rather than full parity.
- This record consolidates architecture/rationale from docs/DESIGN.md and docs/history/PROVENANCE.md. Historical test counts and completion diaries are retired; executable/raw receipts remain at their original paths.
