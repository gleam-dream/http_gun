# Local TLS fixtures

`ca.crt` trusts `localhost.crt`, whose subject alternative name is `localhost`.
`localhost.key` is an intentionally public test key used only by the isolated
loopback server. It is not a provider credential or a production TLS identity.

The same server establishes the positive custom-CA case, unknown-CA rejection,
and trusted-CA/wrong-hostname rejection. Do not add the test CA to system trust.

`ip.crt` / `ip.key` are another intentionally public test identity, signed by
`ip_ca.crt`, with SAN `IP:127.0.0.1` and serverAuth usage. Generated locally on
2026-10-01, valid for ten years. Regenerate with `./dev/env sh dev/ip-fixture`;
the temporary CA private key is removed. Only the IP-SAN test trusts this CA.
The existing DNS-only certificate is the IP-literal negative control. An
initial self-signed leaf was rejected by OTP and is not the retained fixture.
