//// A TLS client certificate chain and the private key that signs for it.
////
//// An identity holds the key in one of two ways. `from_pem` admits an
//// immutable snapshot of a PEM certificate chain and an unencrypted PEM
//// private key. `from_signer` admits a PEM certificate chain and a `Signer`:
//// the private key stays with the application, which signs what the TLS
//// handshake asks it to sign. Applications read credentials from their own
//// secret store. No file is read again on connection replacement. Bind the
//// identity with `config.with_client_identity` before starting a client.
//// Server trust and hostname checks remain enabled and independently
//// configured.
////
//// Rotate by starting a new client with the new identity, directing new work to
//// it, then stopping the old client. Await and consume old application results
//// before stop when they must be retained: shutdown grace covers active HTTP
//// leases, and pool exit ends retained body access. Old exchanges retain their
//// old identity until completion or grace expiry. Views cannot change identity.
////
//// A PEM identity contains private material in memory. Opacity prevents
//// construction or inspection through this API; it is not encryption. Do not
//// log arbitrary configuration or runtime state. HTTP Gun never includes
//// configured identity material, a signing request or a signature in its error
//// descriptions, events or cassettes.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/result

/// An admitted certificate chain with its in-memory private key or its
/// signer. There is no public constructor or accessor for the credential
/// material.
pub opaque type Identity {
  Snapshot(Native)
  External(
    chain: List(BitArray),
    algorithm: Algorithm,
    sign: fn(BitArray, Dynamic, Dynamic) -> Result(BitArray, Nil),
  )
}

// OTP's certificate/key map for `certs_keys`; built and read only natively.
type Native

// The key kind OTP selects signature schemes for. Each atom is an OTP name.
type Algorithm {
  Rsa
}

/// PEM admission failure. No variant contains certificate or private-key input.
pub type Error {
  InvalidCertificateChain
  InvalidPrivateKey
  EncryptedPrivateKey
}

/// A private key that stays outside HTTP Gun, by key kind, and the function
/// that signs with it. May gain variants in a minor release, for other key
/// kinds such as ECDSA.
pub type Signer {
  /// An RSA key. `sign` receives only RSA requests and returns the signature
  /// bytes, or `Error(Nil)` when it cannot or will not sign.
  RsaSigner(sign: fn(RsaRequest) -> Result(BitArray, Nil))
}

/// What a TLS handshake asks an RSA key to sign: the whole `message`, to be
/// hashed with `hash` and signed with `scheme`. In TLS 1.2 the message is the
/// handshake messages exchanged so far; in TLS 1.3 it is the CertificateVerify
/// content. Neither is secret, but neither is useful to log. The scheme is the
/// negotiated one only when the leaf certificate's key is RSA; otherwise OTP may
/// pass no options, which reads as `RsaPkcs1v15`, and the server refuses the
/// handshake.
pub type RsaRequest {
  RsaRequest(message: BitArray, hash: Hash, scheme: RsaScheme)
}

/// The hash a signature covers. OTP's TLS 1.2 and 1.3 defaults sign client
/// certificates with these only; HTTP Gun refuses any other hash, SHA-224 and
/// SHA-1 included, before calling the signer.
pub type Hash {
  Sha256
  Sha384
  Sha512
}

/// An RSA signature scheme.
pub type RsaScheme {
  /// RSASSA-PKCS1-v1_5: the signer encodes the message's hash in a DigestInfo.
  RsaPkcs1v15
  /// RSASSA-PSS with MGF1. TLS sets the salt length to the hash length and the
  /// MGF1 hash to the request's hash; HTTP Gun passes OTP's values unchanged.
  RsaPss(salt_length: Int, mgf1_hash: Hash)
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
pub fn from_pem(
  certificates: String,
  private_key: String,
) -> Result(Identity, Error) {
  pem_snapshot(certificates, private_key) |> result.map(Snapshot)
}

@external(erlang, "http_gun_ffi", "client_identity")
fn pem_snapshot(
  certificates: String,
  private_key: String,
) -> Result(Native, Error)

/// Decode a nonempty PEM certificate chain, leaf first, whose private key the
/// application keeps and signs with through `signer`. The key never enters
/// HTTP Gun's process state. This is pure, like `from_pem`, and fails only with
/// `InvalidCertificateChain`. It does not check that the signer's key is of the
/// signer's kind or belongs to the leaf certificate; the TLS handshake does.
///
/// `sign` runs once per full TLS handshake in which the server asks for a
/// client certificate: the opening handshake of each new connection and each
/// TLS 1.2 renegotiation the server starts. Requests on an open connection
/// never sign, and neither does a resumed TLS 1.2 session. OTP offers no TLS
/// 1.3 resumption by default, and it looks a TLS 1.2 session up by the address
/// HTTP Gun connects to but stores it under the TLS server name; so in practice
/// every new connection to a named host signs, and only an IP-literal origin,
/// which sends no server name, resumes. OTP's session cache is shared by the
/// whole VM: any client with the same certificate chain can resume a session
/// that another client's signer authenticated, without signing.
///
/// One request can open more than one connection. An HTTP/2 connection admits
/// no stream before the server's first SETTINGS, so a request that waits
/// meanwhile opens further connections to the origin, up to the per-origin
/// limit, and each of those handshakes signs.
///
/// `sign` runs in the OTP ssl process of that connection, not in the caller or
/// the client pool, and may call another process, for example with
/// `process.call`. The opening handshake runs under the client's connect
/// timeout; when it expires the request fails with `ConnectTimeout`, but
/// nothing interrupts `sign`, which holds that ssl process until it returns.
/// During a renegotiation only the request's own timeouts apply. So `sign`
/// must bound its own work below the connect timeout and must never block
/// indefinitely. It must not log the message or the signature. The ssl
/// process's mailbox is not the signer's: `sign` must receive only its own
/// replies, selectively, must not link, monitor without demonitoring, trap
/// exits or exit that process, and must leave no message behind, because the
/// ssl process logs an unexpected message with its content. A reply that can
/// arrive after `sign` stopped waiting belongs to a proxy process, not to it.
///
/// When `sign` returns `Error(Nil)`, panics or returns bytes that are not
/// whole, the handshake ends: the client sends a `handshake_failure` alert and
/// discards the exception. A request outside these types (a digest instead of
/// a message, a hash other than SHA-256, SHA-384 or SHA-512, an unknown
/// option) ends it the same way
/// without calling `sign`. Return `Error(Nil)` for a request the signer cannot
/// serve. A failed opening handshake fails the request with
/// `error.ConnectionFailed(error.ClientSigningFailed)` and `NotSent`, which a
/// server refusal never yields. A failed renegotiation follows a sent request,
/// and OTP closes that connection without telling Gun: the request fails only
/// when its own deadline or idle timeout expires, with `MaybeSent`.
///
/// Rotation is as for `from_pem`: start a new client with a new identity. A
/// signer that changes key must come with the matching certificate chain.
pub fn from_signer(
  certificates: String,
  signer: Signer,
) -> Result(Identity, Error) {
  use chain <- result.map(certificate_chain(certificates))
  case signer {
    RsaSigner(sign) ->
      External(chain:, algorithm: Rsa, sign: fn(message, hash, options) {
        rsa_request(message, hash, options) |> result.try(sign)
      })
  }
}

@external(erlang, "http_gun_ffi", "certificates")
fn certificate_chain(certificates: String) -> Result(List(BitArray), Error)

// OTP calls `sign_fun(Message, DigestType, Options)`, as `public_key:sign/4`
// passes them. The native adapter has made the message a binary; this closed
// decoding refuses whatever it does not recognise.
fn rsa_request(
  message: BitArray,
  hash: Dynamic,
  options: Dynamic,
) -> Result(RsaRequest, Nil) {
  use hash <- result.try(
    decode.run(hash, hash_decoder()) |> result.replace_error(Nil),
  )
  use options <- result.try(
    decode.run(options, decode.list(rsa_option_decoder()))
    |> result.replace_error(Nil),
  )
  case options {
    [] -> Ok(RsaRequest(message:, hash:, scheme: RsaPkcs1v15))
    [PssPadding, SaltLength(salt), Mgf1(mgf1)] ->
      Ok(RsaRequest(message:, hash:, scheme: RsaPss(salt, mgf1)))
    _ -> Error(Nil)
  }
}

// The options OTP passes for an RSA-PSS signature, in OTP's order.
type RsaOption {
  PssPadding
  SaltLength(Int)
  Mgf1(Hash)
}

fn rsa_option_decoder() -> decode.Decoder(RsaOption) {
  use name <- decode.field(0, atom.decoder())
  case atom.to_string(name) {
    "rsa_padding" ->
      decode.field(1, atom.decoder(), fn(padding) {
        case atom.to_string(padding) {
          "rsa_pkcs1_pss_padding" -> decode.success(PssPadding)
          _ -> decode.failure(PssPadding, "RSA-PSS padding")
        }
      })
    "rsa_pss_saltlen" ->
      decode.field(1, decode.int, fn(salt) { decode.success(SaltLength(salt)) })
    "rsa_mgf1_md" ->
      decode.field(1, hash_decoder(), fn(hash) { decode.success(Mgf1(hash)) })
    _ -> decode.failure(PssPadding, "RSA signing option")
  }
}

fn hash_decoder() -> decode.Decoder(Hash) {
  use name <- decode.then(atom.decoder())
  case atom.to_string(name) {
    "sha256" -> decode.success(Sha256)
    "sha384" -> decode.success(Sha384)
    "sha512" -> decode.success(Sha512)
    _ -> decode.failure(Sha256, "SHA-2 hash")
  }
}

/// A bounded diagnostic that never includes credential input.
pub fn describe_error(error: Error) -> String {
  case error {
    InvalidCertificateChain -> "client certificate chain is not valid PEM/DER"
    InvalidPrivateKey -> "client private key is not a single supported PEM key"
    EncryptedPrivateKey ->
      "client private key must be decrypted before admission"
  }
}
