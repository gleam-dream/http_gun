# Snapshot client certificate identity per client

<a id="adr-0011"></a>

## Decision

- Admit caller-supplied PEM certificate chains and unencrypted private keys into opaque immutable identity values.
- Bind identity to client configuration and preserve it for every connection in that client pool.
- Rotate by starting a new client, directing new work to it, and draining the old client through the existing stop contract.
- Keep credential acquisition, filesystem access and application identity selection outside HTTP Gun.
- Use OTP public_key parsing and ssl certs_keys options through the existing narrow native bridge.
- Keep proxy routing pending independently of client certificate authentication.

## Rationale and alternatives

- Reading paths during each connection would let file replacement change a client's identity while established pooled connections retained the old identity.
- A mutable identity or per-view identity would require additional pool partitioning and invalidation rules. Client-local immutable pools already provide the required partition.
- Explicit overlap preserves in-flight work and exposes the application's temporary resource budget. No implicit watcher, global registry or rotation process is needed.
- Pure PEM admission separates malformed configuration from connection refusal without introducing a filesystem loader or secret-provider abstraction.
- Certificate trust, expiry, algorithm negotiation and certificate/key pairing remain native TLS decisions. Admission does not claim those properties from parsing alone.
- Password handling and hardware-backed signing require distinct lifetime and failure contracts; they are not implied by support for caller-supplied PEM identities.

## Evidence

- The financial composition review identified mTLS as a required transport capability while retaining its existing payment transport pending qualification.
- The existing pool is per client and its connection settings are immutable. No global origin pool requires another identity key.
- The executable mTLS consumer uses ephemeral test identities and a real local TLS peer. It distinguishes public compilation, native authentication, connection isolation, rotation and conservative lost-response evidence.
- OTP's public ssl certs_keys option accepts in-memory certificate chains and DER private keys: <https://www.erlang.org/doc/apps/ssl/ssl.html#t:cert_key_conf/0>.
