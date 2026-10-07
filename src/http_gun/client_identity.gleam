//// An immutable TLS client certificate and private-key snapshot.
////
//// Applications read credentials from their own secret store, then admit the
//// PEM values with `from_pem`. No file is read again on connection replacement.
//// Bind the identity with `config.with_client_identity` before starting a client.
//// Server trust and hostname checks remain enabled and independently configured.
////
//// Rotate by starting a new client with the new identity, directing new work to
//// it, then stopping the old client. Await and consume old application results
//// before stop when they must be retained: shutdown grace covers active HTTP
//// leases, and pool exit ends retained body access. Old exchanges retain their
//// old identity until completion or grace expiry. Views cannot change identity.
////
//// Identity/configuration values contain private material in memory. Opacity
//// prevents construction or inspection through this API; it is not encryption.
//// Do not log arbitrary configuration or runtime state. HTTP Gun never includes
//// configured identity material in its error descriptions, events or cassettes.

/// An admitted in-memory certificate chain and private key. There is no public
/// constructor or accessor for the credential material.
pub type Identity

/// PEM admission failure. No variant contains certificate or private-key input.
pub type Error {
  InvalidCertificateChain
  InvalidPrivateKey
  EncryptedPrivateKey
}

/// Decode a nonempty PEM certificate chain, leaf first, and exactly one
/// unencrypted PEM private key. This is pure: it starts no process and performs
/// no filesystem or network operation. OTP owns PEM and DER decoding.
///
/// Admission verifies decoding, not trust, expiry, permitted usage, negotiated
/// algorithms or certificate/key pairing. Those remain TLS connection decisions
/// and can fail with the ordinary typed transport cause/submission evidence.
/// Decrypt encrypted keys in the application's credential boundary before this
/// call; HTTP Gun owns no password callback, secret store or file watcher.
@external(erlang, "http_gun_ffi", "client_identity")
pub fn from_pem(
  certificates: String,
  private_key: String,
) -> Result(Identity, Error)

/// A bounded diagnostic that never includes credential input.
pub fn describe_error(error: Error) -> String {
  case error {
    InvalidCertificateChain -> "client certificate chain is not valid PEM/DER"
    InvalidPrivateKey -> "client private key is not a single supported PEM key"
    EncryptedPrivateKey ->
      "client private key must be decrypted before admission"
  }
}
