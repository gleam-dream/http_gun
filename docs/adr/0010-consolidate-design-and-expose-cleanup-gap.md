# Consolidate design authority and expose unresolved cleanup strength

<a id="adr-0010"></a>

## Migration decision

- The 2026-10-06 user instruction authorizes fresh documentation organization, Typst design/glossary, ADR rationale and project-skills setup. This is a documentation migration; it accepts no new runtime behavior.
- Current responsibilities, state, capacity and failure contracts move to `docs/design/design.typ`. Canonical vocabulary moves to its CONTEXT. Material decisions move to ADRs 0001–0009. README, CHANGELOG, testing procedures, examples, fixtures, notices and raw executable/oracle evidence remain useful operational artifacts.
- Retire docs/DESIGN, BOUNDS, GUN_AUDIT, all three never-published migration-wave guides, top-level docs/history reports, five evidence README execution reports and the implementation wave tracker. Preserve their useful contracts/rationale in this layer and operational documents. Preserve raw receipts, hashes, logs, patches and executable evidence; Git retains original prose.

## Unresolved cleanup contract

- `c34a0f5` on 2026-10-04 adds removal attempts on abort and failure. Public prose says staging removal has completed when abort returns and lists only VM death/blocked writes as leftover cases.
- Actual `internal/file.gleam:remove_staging` and `http_gun_file_ffi.erl:remove_staging/1` ignore removal failures and never recurse. `recorder.gleam:remove_staging` can return after 200 ms while a background cleaner waits for writer exit. Permission/storage changes or nested unremovable entries can leave staging data behind.
- This migration documents the implemented attempt and records a ruling gap. It does not approve weakening the original intended cleanup promise or add a runtime fix.

## Alternatives requiring a later owner ruling

- Specify best-effort cleanup explicitly. This preserves the current interface and finite recorder responsiveness but requires operators to handle leftovers and changes the stronger promise in public prose.
- Require typed cleanup completion. This makes deletion failure visible but needs a decision about abort result shape, blocked writers, retry/retention and maximum wait. A timeout cannot prove removal or undo publication.
- Synchronously wait forever would claim eventual cleanup only under unstated filesystem progress and would let a blocked operation freeze abort. It is not a viable finite-lifecycle guarantee.

## Evidence

- Current inspection baseline is `7aa01ce` (2026-10-05). The original prose sources remain retrievable at that revision. This record supplies no invented historical acceptance date or fresh runtime qualification.
- The exact staged installation/deletion and source-to-destination mapping is a disposable migration manifest outside the final layer. The design coverage map states final source ownership rather than authoring progress.

- Historical downstream attribution: the baseline agent guide identified LLM Wire revision `1c0ad614` as the migrated consumer and the archived example as historical evidence. The [original guide](https://github.com/gleam-dream/http_gun/blob/7aa01ce/AGENTS.md) preserves that attribution. Current consumer qualification uses the explicit isolated gate and records the actual tested revisions; this migration does not renew the older result.
