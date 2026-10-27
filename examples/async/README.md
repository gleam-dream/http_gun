# Application-owned streaming jobs

[![CI](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml)
[![http_gun on Hex](https://img.shields.io/hexpm/v/http_gun?label=Hex%3A%20http_gun)](https://hex.pm/packages/http_gun)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate package with public imports. It holds an application recipe for
bounded feed jobs: a worker opens and reads a response body through
`http_gun.with_response`, runs a synchronous sink for each chunk and supports
cancellation and bounded shutdown. The recipe is application code, not an
exported HTTP Gun task API.

## Run

```sh
./dev/env sh dev/async-consumer
```

The runner builds the package, runs a two-job offline demo, then the loopback
test groups. The full gate runs it too. No sibling checkout or provider endpoint
is required.

## Files

- `src/http_gun_async/feed_job.gleam`: the job recipe over one shared supervised client.
- `src/http_gun_async/workflow.gleam`: REST with bounded retry, a byte-counting download and grouped requests.
- `test/http_gun_async_test.gleam`: the executable wiring, including live, script, recording and strict disk playback.
