# Immutable mutual TLS identities

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
