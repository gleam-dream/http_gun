<a id="adr-0017"></a>

# 0017: Offer TLS 1.2 CBC suites as an explicit client choice

Date: 2026-11-10
Status: Accepted

## Decision

A client offers OTP's default cipher suites unless its configuration selects
`config.OtpDefaultsAndTls12Cbc`. That choice appends the TLS 1.2 suites with
ECDHE key exchange, AES-128-CBC or AES-256-CBC encryption and an
HMAC-SHA-256 or HMAC-SHA-384 MAC after the defaults. The setting belongs to
the client, like trust and identity; views cannot change it.

The choice is a closed type, not a list of suite names: every value is valid,
so `config.validate` gains no error case and `ConfigError` keeps its variants.
No other cipher, protocol-version or verification option is exposed. Peer
verification, HTTPS host name matching, trust anchors and destination policy
are unchanged under both choices.

## Rationale and alternatives

- OTP removed CBC suites from its TLS 1.2 defaults. Some servers still accept
  only them. The São Paulo NFS-e web service (`nfe.prefeitura.sp.gov.br`)
  negotiates only `ECDHE-RSA-AES256-SHA384` and closes the connection on the
  default OTP offer, so a client using defaults cannot reach it.
- Arbitrary suite names would let a caller weaken a client in ways HTTP Gun
  cannot describe or test, and would need a new `ConfigError` variant, a
  breaking change against the published 0.1.0 baseline.
- A per-host option would require the pool to partition connections by cipher
  policy. A separate client per compatibility need already gives that
  partition, as it does for client identities (ADR 0011).
- Appending after the defaults keeps forward secrecy (ECDHE only) and lets a
  server that supports a default suite select it. Static RSA key exchange,
  SHA-1 MACs and non-AES ciphers stay excluded.

## Evidence

- A local OTP TLS server restricted to TLS 1.2 and `ECDHE-RSA-AES256-SHA384`
  refuses the default client before submission (NotSent) and serves the
  client that selects `OtpDefaultsAndTls12Cbc`
  (`test/http_gun_cipher_test.gleam`).
- `openssl s_client` and OTP `ssl:connect` against the São Paulo service on
  2026-11-10: only `ECDHE-RSA-AES256-SHA384` over TLS 1.2 was negotiated;
  OTP defaults were closed by the peer.
