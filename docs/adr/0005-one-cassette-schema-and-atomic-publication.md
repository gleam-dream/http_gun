# One cassette schema and atomic publication separate capture from HTTP

<a id="adr-0005"></a>

## Decision

- Use one current schema marked `http_gun: 2`. Unsupported versions fail rather than entering a legacy decoder or live fallback.
- Reserve exchange order before live work, write acknowledged fragments through one writer, and finalize only terminal reservations. Capture failures are independent from HTTP results.
- Publish through a hard link when replacement is refused and rename when explicitly enabled. Stage beside the destination. Atomic visibility is the guarantee; power-loss durability is not.
- Use file_streams for bounded raw input and exclusive writes, simplifile for permission/link/rename operations, and small missing-primitive FFI for unique candidates and nonrecursive cleanup.

## Rationale and alternatives

- First-match fixture lookup or mismatch consumption loses ordered repeated-request behavior. Automatic rerecording or network fallback can hide invalid tests and expose credentials.
- A separate legacy runtime schema adds permanent burden to an unreleased package. The retained standalone converter is an explicit tool, not decoder fallback.
- A check-before-create or check-before-overwrite sequence cannot establish exclusive publication. Filesystem link/rename supplies the commit point.
- Buffered whole-session capture would grow with response data and obscure writer completion. Acknowledged fragments and bounded whole-body redaction retain an explicit storage budget.
- File synchronization alone does not establish directory-entry durability across platforms. A durable publication feature remains an owner scope decision.

## Evidence

- `ebf2b47` (2026-09-30) records earlier controls/capture simplification. `e55fa1d` (2026-10-02) selects schema 2 and release modules.
- `cassette.gleam`, `internal/codec.gleam`, `internal/recorder.gleam`, `internal/file.gleam`, `redaction.gleam`, cassette/recording/fault tests.
- Local FILESYSTEM and API_ERGONOMICS decisions consolidate here. Their outdated claims of unimplemented body/query redaction are superseded by current code. `dev/convert_cassette.py` remains usable for explicit old fixture conversion.
