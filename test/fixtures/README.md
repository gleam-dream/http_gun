# Local TLS fixtures

`ca.crt` trusts `localhost.crt`, whose subject alternative name is `localhost`.
`localhost.key` is an intentionally public test key used only by the isolated
loopback server. It is not a provider credential or a production TLS identity.

The same server establishes the positive custom-CA case, unknown-CA rejection,
and trusted-CA/wrong-hostname rejection. Do not add the test CA to system trust.
