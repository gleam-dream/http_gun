# Patch ranges require native contract audits before widening

<a id="adr-0007"></a>

## Decision

- Depend on Gun `>= 2.6.0 and < 2.7.0` and Cowlib `>= 2.20.0 and < 2.21.0`. Qualify the committed minimum and newest patch in CI.
- Re-audit undocumented native assumptions before widening to another minor or relying on additional message/info/error fields.

## Rationale and alternatives

- Exact pins block consumer security-patch uptake. Unrestricted minor ranges permit unreviewed changes to terms the manuals do not contract.
- Missing H1 state_name connected must refuse reuse. Unknown native error terms map to UnknownTransport. Neither case upgrades evidence or resends requests.
- Test-only Cowlib framing/HPACK modules are also undocumented. Their incompatibility can invalidate H2 evidence even when production calls still compile.

## Evidence

- Audit recorded on 2026-10-02 against Gun 2.6.0/Cowlib 2.20.0. `c55934a` records min/latest-patch CI; `e55fa1d` records release range selection.
- `gleam.toml`, `manifest.toml`, `.github/workflows/check.yml`, `dev/boundaries.py`, `src/http_gun_ffi.erl`, `test/http_gun_h2_server.erl`.
- Operational re-audit procedure is in [DEPENDENCY-UPGRADES.md](../DEPENDENCY-UPGRADES.md). Detailed old GUN_AUDIT rationale is consolidated here; its useful procedures/assumption inventory remain current.
