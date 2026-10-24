# Local TLS fixtures

Intentionally public test identities for the isolated loopback servers. None is
a provider credential or a production TLS identity, and the test CAs never enter
system trust.

- `ca.crt` signs `localhost.crt` (SAN `localhost`), used for the custom-CA positive case, unknown-CA rejection and wrong-hostname rejection.
- `ip.crt` and `ip.key` carry SAN `IP:127.0.0.1` with serverAuth usage, signed by `ip_ca.crt`. Regenerate with `./dev/env sh dev/ip-fixture`. The DNS-only certificate is the IP-literal negative control.
