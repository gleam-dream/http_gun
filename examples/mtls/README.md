# Immutable mutual TLS identities

This separate consumer imports only public HTTP Gun modules. Its local server
requires a trusted client certificate and reports the actual peer identity and
connection. The application projects ordinary HTTP responses into its own
`Receipt` and `FetchError` types.

## Run

From the HTTP Gun repository:

```sh
./dev/env sh dev/mtls-consumer
```

The runner creates an isolated package workspace, resolves the root's selected
Gun/Cowlib patches, generates ephemeral OpenSSL test certificates in a temporary
directory, and runs this consumer from that directory in the repository's Nix
shell. It independently compiles the native test peer with warnings rejected.
The full package gate includes this runner. No provider or production credential
is used. The generated CA is never installed in system trust.

## Behaviors

- Ordinary H1 over TLS 1.2 and TLS 1.3, and required H2 over TLS 1.3, present an RSA client certificate with an intermediate chain.
- Missing and untrusted client identities fail with typed certificate refusal. A corrected client can call the same server. A mismatched certificate/key fails through native TLS.
- PEM admission refuses malformed chains, malformed/multiple keys and encrypted keys with credential-free errors.
- Two clients authenticate as different RSA/EC identities against one H2 origin. Each reuses its own authenticated connection.
- Replacing application credential files cannot change the admitted identity on a reconnect.
- Rotation starts a new identity while an old exchange is gated. The caller consumes the old result under its original identity before stopping the old client. Zero shutdown grace can instead end an active exchange locally.
- In-memory server trust and a pinned resolver preserve hostname checks and a narrowed destination policy.
- A server that receives an authenticated request and closes without responding produces `MaybeSent` with one observed request and no automatic retry.
- Recording and observations omit configured certificate/key bytes. Playback uses the captured HTTP exchange without a TLS identity or network fallback.

## Ownership and qualification limits

- The caller reads credentials and handles their errors. HTTP Gun admits an immutable in-memory identity and never rereads paths or watches files.
- The caller switches application work to a new client and accounts for overlap capacity. To retain old application results, await and consume them before stopping the old client. Shutdown grace covers active HTTP leases; pool exit ends retained body access even after HTTP EOF.
- PEM decoding does not establish trust, expiry, permitted usage or certificate/key pairing. Native TLS establishes those properties for the connection.
- TLS 1.3 may reject client authentication after the local handshake succeeds. Failures preserve actual submission evidence rather than declaring every authentication refusal `NotSent`.
- This is executable local TLS evidence, not provider certification, a production rotation deployment, or an external-effect idempotency guarantee. Password callbacks and hardware-backed keys are outside this PEM interface.
- Test fixtures and the minimal native test peer are authored here. Gun/Cowlib retain wire ownership in production; no dependency source is patched.
