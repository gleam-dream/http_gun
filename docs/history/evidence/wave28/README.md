# Destination policy qualification — 2026-10-01

The working implementation is based on HTTP Gun2b3656e8. It is not committed or
released. [receipt.json](receipt.json) records the final scope, versions and
outcomes; [inputs.json](inputs.json) pins106 runtime/dependency inputs.

- Fast: `./dev/env sh dev/gate fast`,120 passing tests; log in
  [wave27](../wave27/fast-final-with-cancellation.log).
- Full OTP29: `./dev/env sh dev/gate full`; [passing log](full.log).
- Full OTP28/27: `sh docs/evidence/wave28/remaining-matrix.sh`;
  [driver](remaining-matrix.sh), [logs and measurements](runtimes/).
- Public docs: `./dev/env gleam docs build`; [log](docs-build.log).
- Actual downstream: `./dev/env python3 dev/check_downstream.py --http-gun
/code/gleam-dream/http_gun --llm-wire /code/gleam-dream/llm_wire --output
/private/tmp/http-gun-destination-downstream-original`. It compiles but has
  48 expected local-policy test failures; [receipt](downstream-original/receipt.json).
- Explicit disposable test-setup adaptation:
  `./dev/env python3 docs/evidence/wave28/adapted-downstream.py`;
  [script](adapted-downstream.py), [exact setup patch](downstream-adapted/setup.patch),
  [passing223-test/boundary/H2 receipt](downstream-adapted/receipt.json).
  The script requires a new output directory. Original siblings remain unchanged.
- SNI negative control:
  `./dev/env python3 docs/evidence/wave28/ip-sni-mutation.py`;
  [result](ip-sni-mutation.json). Only a temporary HTTP Gun copy uses the unsafe
  SNI=disable option; the negative certificate test catches it.

The first full gate found a test-example alias mistake; full-first.log is its
failed receipt. Earlier policy/header reds, fixture correction and parser probe
are retained under waves25–27. The short-connect experiment passed and is not
labeled a reproduced defect. Runtime inputs match the final full-gate source;
subsequent edits only summarize documentation/evidence.

Warden reference source/tests were hashed before implementation and unchanged
afterward. No donor source was copied, no dependency patched, and no Warden
migration/adapter gate or release performed. The accepted reason-phrase
exception and exact DNS/header/deadline boundaries are in BOUNDS.md.
