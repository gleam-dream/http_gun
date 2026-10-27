# Local HTTP comparison

[![CI](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml)
[![http_gun on Hex](https://img.shields.io/hexpm/v/http_gun?label=Hex%3A%20http_gun)](https://hex.pm/packages/http_gun)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate package that compares the public HTTP Gun and Dream APIs over local
HTTP/1.1 servers. `comparison_adapter` keeps status, error and body differences
and gives the workload driver one call shape. `comparison_contract` exercises
behavior; the timing run measures workloads.

The pinned references and how outcomes are classified are in
[ORACLE.md](../../docs/ORACLE.md). The method, run commands and retained
measurements are in [BENCHMARKS.md](../../docs/BENCHMARKS.md).

The full gate compiles this package and runs its behavioral contracts against the current HTTP Gun source. Timing benchmarks remain in scheduled qualification.

## Run

From the HTTP Gun root, run the wrapper:

```sh
./dev/env python3 dev/comparison/run.py all --trials 3 --output build/comparison-recheck
```

Use a new output directory to keep earlier receipts. `contracts`, `bench --trials 3`
and `upstream` run single parts, and `summary` recomputes statistics from saved
measurements.
