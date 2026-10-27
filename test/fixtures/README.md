# Local TLS fixtures

[![CI](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml/badge.svg?branch=main)](https://github.com/gleam-dream/http_gun/actions/workflows/check.yml)
[![http_gun on Hex](https://img.shields.io/hexpm/v/http_gun?label=Hex%3A%20http_gun)](https://hex.pm/packages/http_gun)
[![Gleam](https://img.shields.io/badge/Gleam-FFAFF3?logo=gleam&logoColor=000000)](https://gleam.run/)

Intentionally public test identities for the isolated loopback servers. None is
a provider credential or a production TLS identity, and the test CAs never enter
system trust.

- `ca.crt` signs `localhost.crt` (SAN `localhost`), used for the custom-CA positive case, unknown-CA rejection and wrong-hostname rejection.
- `ip.crt` and `ip.key` carry SAN `IP:127.0.0.1` with serverAuth usage, signed by `ip_ca.crt`. Regenerate with `./dev/env sh dev/ip-fixture`. The DNS-only certificate is the IP-literal negative control.
