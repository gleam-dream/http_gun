# Immutable mutual TLS identities

[![CI](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml)
[![http_gun on Hex](https://img.shields.io/hexpm/v/http_gun?label=Hex%3A%20http_gun)](https://hex.pm/packages/http_gun)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

A separate package that imports only public HTTP Gun modules. Its local server
requires a trusted client certificate and reports the peer identity and
connection. The application projects HTTP responses into its own `Receipt` and
`FetchError` types.

## Run

```sh
./dev/env sh dev/mtls-consumer
```

The runner creates an isolated workspace, generates ephemeral OpenSSL test
certificates in a temporary directory and runs the consumer in the repository's
Nix shell. The full gate includes it. No provider or production credential is
used, and the generated CA is never installed in system trust.
