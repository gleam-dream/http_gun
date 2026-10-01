# Current downstream validation

LLM Wire migrated to HTTP Gun at `1c0ad614149b6ba286a6f778e223bd294f403b30`, using HTTP Gun `ebf2b479761e8c932b0c85a8f83cf8460c014d4f`. The package remains unreleased, but it now has a real downstream consumer. Changes may break unreleased APIs deliberately; qualify them against the selected consumer and state any required downstream change.

Run separately from the normal package gate:

```sh
./dev/env python3 dev/check_downstream.py \
  --http-gun /code/gleam-dream/http_gun \
  --llm-wire /code/gleam-dream/llm_wire \
  --output /private/tmp/http-gun-downstream-receipt
```

The output directory must be new and outside input checkouts. Run from HTTP Gun's root with its pinned toolchain. The driver discovers the selected consumer's local dependencies (`json_blueprint` and `sinal` at the reviewed revision), copies tracked and non-ignored working files, and relocates local manifest paths only in those copies. Builds and generated files cannot change siblings. HTTP Gun and LLM Wire must resolve the same Sinal checkout; the driver verifies it against the pinned source used by the normal gate before building. Repository archives, builds and old evidence are excluded. Internal source symlinks are dereferenced; escaping symlinks are refused. Source hashes, Git revisions/status, exact commands, runtime logs and original-file rechecks identify the tested input. A dirty checkout is supported and reported; it is not represented as identical to HEAD.

Checks: Gleam check/build with warnings as errors, the actual downstream test suite, `test/external_package_boundary.sh` (valid consumer before six intended type restrictions), and `dev/local-http.py` (nghttpd TLS/H2, cancellation with healthy siblings and concurrency). Recording/playback, tools and structured output are exercised by the downstream suite and public consumer. All HTTP uses loopback or strict offline scripts; no provider credentials are needed. This is an integration gate for the reviewed downstream layout, not a generic command/plugin runner. If that layout changes, update the explicit commands after review.

Keep three evidence layers distinct:

1. The ordinary example checks public HTTP values, requests, scopes, batch and modes without sibling packages.
2. The maintained asynchronous example checks worker ownership, cancellation composition and supervision without sibling packages.
3. This opt-in gate checks the actual selected LLM Wire revision. Its historical archive remains useful scenario evidence, never a substitute for this check.

The normal fast/full gate remains reproducible without these checkouts. Run the downstream gate when changing public contracts, before adopting a new local HTTP Gun revision. A passing receipt applies to its recorded bytes, inputs and runtime; it is not a promise about arbitrary consumers or future revisions.


## Destination-policy adoption (2026-10-01)

HTTP Gun now defaults to public destinations only. Local test clients need:

```gleam
import http_gun/config
import http_gun/destination

fn local_settings() -> config.Config {
  let defaults = config.default()
  config.Config(..defaults, destination:
    destination.Policy(..defaults.destination, allow_loopback: True))
}
```

The actual LLM Wire1c0ad614 still passes check/build, including its existing
failure mapping. Its unmodified suite reports175 passes/48 failures from local
clients lacking this opt-in. In isolated copies, changing only test/example
startup configuration yields223 passing tests, public boundary checks and local
TLS/H2 through1000 callers. Production modules and original checkouts are
unchanged. The [experiment receipt](evidence/wave28/downstream-adapted/receipt.json)
and [exact setup patch](evidence/wave28/downstream-adapted/setup.patch) distinguish
that qualified adaptation from the [unmodified result](evidence/wave28/downstream-original/receipt.json).
The ordinary downstream gate performs no such patch automatically.

Consumers with exhaustive error matches add DestinationRejected and
ResolutionFailed; both precede live HTTP submission. Keep public-only policy
for public endpoints and opt into private/loopback destinations deliberately.
A changed policy requires a new client, including after supervision restart.
Warden's own transport migration and unchanged-through-adapter tests have not
been performed here; neither a release nor adoption is claimed.
