# Local HTTP comparison

A separate package that compares the public HTTP Gun and Dream APIs over local
HTTP/1.1 servers. `comparison_adapter` keeps status, error and body differences
and gives the workload driver one call shape. `comparison_contract` exercises
behavior; the timing run measures workloads.

The pinned references and how outcomes are classified are in
[ORACLE.md](../../docs/ORACLE.md). The method, run commands and retained
measurements are in [BENCHMARKS.md](../../docs/BENCHMARKS.md).

## Run

From the HTTP Gun root, materialize the bundled Sinal snapshot, then run the
wrapper:

```sh
./dev/env python3 dev/sinal_source.py build/dream-comparison/sinal
./dev/env python3 dev/comparison/run.py all --trials 3 --output build/comparison-recheck
```

Use a new output directory to keep earlier receipts. `contracts`, `bench --trials 3`
and `upstream` run single parts, and `summary` recomputes statistics from saved
measurements.
