# Pinned Dream comparison consumer

This separate Gleam package imports only the public HTTP Gun and Dream APIs. Its path dependencies resolve after `dev/comparison/run.py` copies it into ignored `build/dream-comparison/runner` alongside the two isolated client packages. Run it through the wrapper from the HTTP Gun root:

```sh
./dev/env python3 dev/comparison/run.py all
```

`comparison_adapter` preserves observable status/error/body differences while giving the workload driver a common call shape. `comparison_contract` checks binary responses, status handling, duplicates/trailers, local TLS, early closure, owner exit, explicit Dream callback cancellation and actual offline record/replay. `comparison` measures warmed H1 requests at 1/10/100/1000 callers, four bounded workers, 32 MiB streams, slow readers and mixed same-origin work.

The wrapper supplies the reviewed test servers, local certificates and sampler from HTTP Gun's test directory. `comparison_ffi.erl` adds argument conversion and finite sequence/mixed-response servers; it is not production code. Dream's downloaded source and MIT notice stay in its isolated archive checkout, with hashes recorded before use. No Dream source is copied into this package.

The comparison lock is shared by the two clients. Public connection settings have different semantics; the four-worker case controls application concurrency equally. See the [method, results and qualifications](../../docs/DREAM_COMPARISON.md) before interpreting measurements. Existing evidence is overwritten when phases are rerun.

Use `--output docs/evidence/<new-directory>` to preserve an earlier comparison. The pinned donor source receipt stays in `docs/evidence/dream-comparison/source.json`; each output directory receives its own current implementation receipt, contract results and measurements.
