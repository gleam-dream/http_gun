# Ordinary consumer

[![CI](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml)
[![http_gun on Hex](https://img.shields.io/hexpm/v/http_gun?label=Hex%3A%20http_gun)](https://hex.pm/packages/http_gun)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate package that imports only public HTTP Gun modules. Each module is a
runnable usage example against local servers, and `http_gun_consumer.main` runs
them all.

| Module                | Shows                                                                                            |
| --------------------- | ------------------------------------------------------------------------------------------------ |
| `usage_configure`     | Defaults, configuration, validation errors and explicit timeouts                                 |
| `usage_views`         | Client views, correlation, streamed bodies, owner rules, body limits and batches                 |
| `usage_destinations`  | Destination policies, plaintext rules and one client shared by tenants                           |
| `usage_offline`       | Scripted playback, mismatch and exhaustion, a failure that keeps its head and cassette redaction |
| `http_gun_consumer`   | Supervision, failure handling, observation routes and labels, record and replay                  |
| `cancellation_checks` | Application and operation cancellation before submission, while queued and while streaming       |

## Run

```sh
./dev/env sh dev/consumers
```

The full gate runs it, so an example that no longer matches the library fails the
gate. No provider endpoint or sibling checkout is needed. Start from
`src/http_gun_consumer.gleam`.
