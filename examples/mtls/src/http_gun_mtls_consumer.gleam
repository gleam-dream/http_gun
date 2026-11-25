//// Public mTLS consumer: application-owned credential input, native results,
//// independent trust, identity isolation, rotation and conservative recovery,
//// and identities whose private key stays in an application signer process.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/otp/actor
import gleam/result
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/client_identity
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/telemetry
import http_gun/testing
import simplifile
import sinal

type Protocol {
  H1
  H1Tls12
  /// TLS 1.2 whose certificate request offers RSA PKCS#1 v1.5 only.
  H1Tls12Pkcs1
  /// TLS 1.2 that resumes sessions. Like OTP's default for a server that
  /// verifies clients, the others resume none.
  H1Tls12Resume
  H2
}

@external(erlang, "http_gun_mtls_server", "start")
fn server(protocol: Protocol) -> #(Int, process.Pid)

@external(erlang, "http_gun_mtls_server", "stop")
fn stop_server(server: process.Pid) -> Nil

@external(erlang, "http_gun_mtls_server", "pem")
fn pem(name: String) -> String

@external(erlang, "http_gun_mtls_server", "path")
fn path(name: String) -> String

@external(erlang, "http_gun_mtls_server", "anchors")
fn anchors() -> List(BitArray)

@external(erlang, "http_gun_mtls_server", "await_held")
fn await_held() -> process.Pid

@external(erlang, "http_gun_mtls_server", "release")
fn release(server: process.Pid) -> Nil

@external(erlang, "http_gun_mtls_server", "await_request")
fn await_request() -> #(String, String, String)

@external(erlang, "http_gun_mtls_server", "requests")
fn requests(count: Int) -> Int

// The application chooses its own output and errors from ordinary HTTP.
type Receipt {
  Receipt(identity: String, connection: String)
}

type FetchError {
  Http(error.Failure)
  UnexpectedStatus(Int)
  InvalidReply
}

fn fetch(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(Receipt, FetchError) {
  use reply <- result.try(http_gun.send(client, req) |> result.map_error(Http))
  case reply.response.status {
    200 -> {
      use identity <- result.try(
        bit_array.to_string(reply.response.body)
        |> result.map_error(fn(_) { InvalidReply }),
      )
      use connection <- result.try(
        response.get_header(reply.response, "x-connection")
        |> result.map_error(fn(_) { InvalidReply }),
      )
      Ok(Receipt(identity, connection))
    }
    status -> Error(UnexpectedStatus(status))
  }
}

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) = request.to("https://localhost:" <> int.to_string(port))
  request.set_body(req, <<>>)
}

fn settings() -> config.Config {
  config.default()
  |> config.allow_loopback
  |> config.with_trust(config.CustomCa(path("server-ca.crt")))
}

fn identity(name: String) -> client_identity.Identity {
  let cert = case name {
    "a" -> "a-chain"
    _ -> name
  }
  let assert Ok(identity) =
    client_identity.from_pem(pem(cert <> ".crt"), pem(name <> ".key"))
  identity
}

pub fn main() {
  list.each([H1, H1Tls12, H2], authenticated)
  rejected_identity_and_recovery()
  malformed_credentials()
  distinct_identities()
  snapshot_reconnect()
  rotation_waits_for_old_application_work()
  rotation_can_expire_old_exchange()
  advanced_policy_keeps_server_verification()
  lost_response_has_no_retry()
  capture_omits_identity()
  signer_schemes()
  signer_reuse()
  signer_failures()
  signer_renegotiation()
  signer_connect_timeout()
  signer_leaves_no_trace()
  io.println("PASS mTLS public consumer: 18 native/admission/lifecycle groups")
}

fn http_protocol(protocol: Protocol) -> config.Protocol {
  case protocol {
    H2 -> config.RequireHttp2
    _ -> config.Http1
  }
}

fn authenticated(protocol: Protocol) {
  let #(port, peer) = server(protocol)
  let assert Ok(client) =
    settings()
    |> config.with_protocol(http_protocol(protocol))
    |> config.with_client_identity(case protocol {
      H2 -> identity("a")
      _ -> {
        let assert Ok(rsa) =
          client_identity.from_pem(pem("a-chain.crt"), pem("a-rsa.key"))
        rsa
      }
    })
    |> http_gun.start
  let assert Ok(reply) = http_gun.send(client, req(port))
  let assert <<"a":utf8>> = reply.response.body
  let assert True =
    reply.protocol
    == case protocol {
      H2 -> config.H2
      _ -> config.H1
    }
  let assert #("/", "a", _) = await_request()
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS native TLS presents the configured chain and client identity",
  )
}

fn rejected_identity_and_recovery() {
  let #(port, peer) = server(H1)
  list.each(
    [settings(), settings() |> config.with_client_identity(identity("wrong"))],
    fn(c) {
      let assert Ok(client) = http_gun.start(c)
      let assert Error(Http(failure)) = fetch(client, req(port))
      let assert True = case error.reason(failure) {
        error.ConnectionFailed(error.CertificateRejected)
        | error.RequestFailed(error.CertificateRejected) -> True
        _ -> False
      }
      let assert 0 = requests(0)
      credentials_absent(error.describe(failure))
      http_gun.stop(client)
    },
  )
  // Correction is explicit; the caller starts a correctly configured client.
  let assert Ok(client) =
    settings() |> config.with_client_identity(identity("a")) |> http_gun.start
  let assert Ok(Receipt("a", _)) = fetch(client, req(port))
  let _ = await_request()
  http_gun.stop(client)
  stop_server(peer)
  // Mismatched but decodable credentials remain a typed TLS failure.
  let #(port, peer) = server(H1)
  let assert Ok(mismatch) =
    client_identity.from_pem(pem("a-chain.crt"), pem("wrong.key"))
  let assert Ok(client) =
    settings() |> config.with_client_identity(mismatch) |> http_gun.start
  let assert Error(failure) = http_gun.send(client, req(port))
  let assert error.Network = error.kind(failure)
  let assert True = case error.reason(failure) {
    error.ConnectionFailed(error.CertificateRejected)
    | error.ConnectionFailed(error.TlsFailed)
    | error.RequestFailed(error.CertificateRejected)
    | error.RequestFailed(error.TlsFailed) -> True
    _ -> False
  }
  let assert 0 = requests(0)
  credentials_absent(error.describe(failure))
  http_gun.stop(client)
  stop_server(peer)
  io.println("PASS missing/rejected/mismatched identity and explicit recovery")
}

fn malformed_credentials() {
  let assert Error(client_identity.InvalidCertificateChain) =
    client_identity.from_pem("", pem("a.key"))
  let assert Error(client_identity.InvalidCertificateChain) =
    client_identity.from_pem(
      "-----BEGIN CERTIFICATE-----\nAQID\n-----END CERTIFICATE-----",
      pem("a.key"),
    )
  let assert Error(client_identity.InvalidPrivateKey) =
    client_identity.from_pem(pem("a-chain.crt"), "not a key")
  let assert Error(client_identity.InvalidPrivateKey) =
    client_identity.from_pem(pem("a-chain.crt"), pem("a.key") <> pem("a.key"))
  let assert Error(client_identity.EncryptedPrivateKey) =
    client_identity.from_pem(pem("a-chain.crt"), pem("encrypted.key"))
  let assert Ok(_) =
    client_identity.from_pem(pem("a-chain.crt"), pem("a-rsa.key"))
  list.each(
    [
      client_identity.InvalidCertificateChain,
      client_identity.InvalidPrivateKey,
      client_identity.EncryptedPrivateKey,
    ],
    fn(error) { credentials_absent(client_identity.describe_error(error)) },
  )
  io.println("PASS PEM admission produces typed credential-free failures")
}

fn distinct_identities() {
  let #(port, peer) = server(H2)
  let c =
    settings()
    |> config.with_protocol(config.RequireHttp2)
    |> config.with_max_connections(1)
  let assert Ok(a) =
    c |> config.with_client_identity(identity("a")) |> http_gun.start
  let assert Ok(b) =
    c |> config.with_client_identity(identity("b")) |> http_gun.start
  let assert Ok(first) = fetch(a, req(port))
  let assert Ok(second) = fetch(b, req(port))
  let assert Ok(again) = fetch(a, req(port))
  let assert "a" = first.identity
  let assert "b" = second.identity
  let assert True = first.connection != second.connection
  let assert True = first == again
  let assert 3 = requests(0)
  http_gun.stop(a)
  http_gun.stop(b)
  stop_server(peer)
  io.println("PASS H2 reuse stays inside the client identity partition")
}

fn snapshot_reconnect() {
  let #(port, peer) = server(H1)
  let cert_path = path("rotating.crt")
  let key_path = path("rotating.key")
  let assert Ok(_) = simplifile.write(cert_path, pem("a-chain.crt"))
  let assert Ok(_) = simplifile.write(key_path, pem("a.key"))
  let assert Ok(cert) = simplifile.read(cert_path)
  let assert Ok(key) = simplifile.read(key_path)
  let assert Ok(snapshot) = client_identity.from_pem(cert, key)
  let assert Ok(client) =
    settings() |> config.with_client_identity(snapshot) |> http_gun.start
  let assert Ok(first) = fetch(client, req(port) |> request.set_path("/close"))
  let assert Ok(_) = simplifile.write(cert_path, pem("b.crt"))
  let assert Ok(_) = simplifile.write(key_path, pem("b.key"))
  let assert Ok(second) = fetch(client, req(port))
  let assert "a" = first.identity
  let assert "a" = second.identity
  let assert True = first.connection != second.connection
  let assert 2 = requests(0)
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS reconnect keeps snapshot after application credential files change",
  )
}

fn rotation_waits_for_old_application_work() {
  let #(port, peer) = server(H1)
  let c = settings() |> config.with_max_connections(1)
  let assert Ok(old) =
    c |> config.with_client_identity(identity("a")) |> http_gun.start
  let assert Ok(held) =
    http_gun.open(old, req(port) |> request.set_path("/held"))
  let held_peer = await_held()
  let assert Ok(new) =
    c |> config.with_client_identity(identity("b")) |> http_gun.start
  let assert Ok(Receipt("b", _)) = fetch(new, req(port))
  // The new identity has already served work while the old exchange is held.
  // Await old application results before stop: HTTP EOF can precede body reads.
  release(held_peer)
  let assert Ok(body.Collected(<<"a":utf8>>, _)) = body.collect(held.body, 10)
  body.close(held.body)
  http_gun.stop(old)
  let assert Error(failure) = http_gun.send(old, req(port))
  let assert error.ClientClosed = error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert 2 = requests(0)
  http_gun.stop(new)
  stop_server(peer)
  io.println(
    "PASS rotation overlaps identities and awaits old results before stop",
  )
}

fn rotation_can_expire_old_exchange() {
  let #(port, peer) = server(H1)
  let assert Ok(old) =
    settings()
    |> config.with_client_identity(identity("a"))
    |> config.with_shutdown_timeout(duration.milliseconds(0))
    |> http_gun.start
  let assert Ok(held) =
    http_gun.open(old, req(port) |> request.set_path("/held"))
  let _ = await_held()
  http_gun.stop(old)
  let assert Error(_) = body.next(held.body)
  let assert 1 = requests(0)
  stop_server(peer)
  io.println(
    "PASS existing shutdown grace can terminate an old identity exchange",
  )
}

fn advanced_policy_keeps_server_verification() {
  let #(port, peer) = server(H1)
  let c =
    settings()
    |> config.with_trust(config.Anchors(anchors()))
    |> config.with_client_identity(identity("b"))
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(127, 0, 0, 1)]) })
  let assert Ok(client) = http_gun.start(c)
  let assert Ok(Receipt("b", _)) = fetch(client, req(port))
  let _ = await_request()
  let assert Ok(Receipt("b", _)) =
    fetch(client, req(port) |> request.set_host("127.0.0.1"))
  let _ = await_request()
  let assert Error(failure) =
    http_gun.send(client, req(port) |> request.set_host("wrong.invalid"))
  let assert error.ConnectionFailed(error.CertificateRejected) =
    error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert 0 = requests(0)
  let view = client |> http_gun.with_destination(destination.default())
  let assert Error(refused) = http_gun.send(view, req(port))
  let assert error.Refused = error.kind(refused)
  let assert error.NotSent = error.evidence(refused)
  let assert 0 = requests(0)
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS custom anchors and resolver retain hostname and destination policy",
  )
}

fn lost_response_has_no_retry() {
  let #(port, peer) = server(H1)
  let assert Ok(client) =
    settings() |> config.with_client_identity(identity("a")) |> http_gun.start
  let assert Error(failure) =
    http_gun.send(
      client,
      req(port) |> request.set_method(http.Post) |> request.set_path("/loss"),
    )
  let assert error.MaybeSent = error.evidence(failure)
  let assert 1 = requests(0)
  let assert False = error.is_retryable(failure, False)
  credentials_absent(error.describe(failure))
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS authenticated lost response remains MaybeSent without replay",
  )
}

fn capture_omits_identity() {
  let #(port, peer) = server(H1)
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      process.send(events, string.inspect(#(time, metadata)))
    })
  let assert Ok(recorded) =
    cassette.record(
      settings() |> config.with_client_identity(identity("a")),
      path("mtls.json"),
      cassette.options(),
    )
  let assert Ok(Receipt("a", _)) = fetch(recorded.client, req(port))
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(1))
  http_gun.stop(recorded.client)
  let assert Ok(_) = sinal.detach(attachment)
  let assert True = check_events(events, 0) > 0
  let assert Ok(recording) = simplifile.read(path("mtls.json"))
  credentials_absent(recording)
  let assert Ok(script) = cassette.load(path("mtls.json"), 100_000)
  let assert Ok(playback) = testing.playback(script, config.default())
  let assert Ok(Receipt("a", _)) = fetch(playback, req(port))
  http_gun.stop(playback)
  let assert 1 = requests(0)
  stop_server(peer)
  io.println(
    "PASS capture and observations omit configured credentials; playback needs no identity",
  )
}

fn check_events(events: process.Subject(String), count: Int) -> Int {
  case process.receive(events, 0) {
    Ok(event) -> {
      credentials_absent(event)
      check_events(events, count + 1)
    }
    Error(_) -> count
  }
}

fn credentials_absent(text: String) {
  list.each(["a-chain.crt", "a.key", "b.crt", "b.key", "wrong.key"], fn(name) {
    pem(name)
    |> string.split("\n")
    |> list.filter(fn(line) { string.length(line) > 32 })
    |> list.each(fn(line) {
      let assert False = string.contains(text, line)
    })
  })
}

// The private key stays in this process. The identity holds only a function
// that asks it to sign; the process records what each handshake asked for.
type KeyMessage {
  Sign(client_identity.RsaRequest, process.Subject(Result(BitArray, Nil)))
  Asked(
    process.Subject(List(#(client_identity.Hash, client_identity.RsaScheme))),
  )
  Material(process.Subject(List(BitArray)))
}

@external(erlang, "http_gun_mtls_server", "capture_logs")
fn capture_logs() -> Nil

/// Stop capturing; the number of log events and whether any held a needle.
@external(erlang, "http_gun_mtls_server", "logged")
fn logged(needles: List(BitArray)) -> #(Int, Bool)

@external(erlang, "http_gun_mtls_server", "contains")
fn contains(haystack: BitArray, needle: BitArray) -> Bool

@external(erlang, "http_gun_mtls_server", "sign")
fn rsa_sign(
  key: String,
  message: BitArray,
  hash: client_identity.Hash,
  scheme: client_identity.RsaScheme,
) -> BitArray

/// A key process that signs at most `signatures` requests, then refuses.
fn key_holder(name: String, signatures: Int) -> process.Subject(KeyMessage) {
  let key = pem(name)
  let assert Ok(started) =
    actor.new(#(signatures, [], []))
    |> actor.on_message(fn(state, message) {
      let #(left, asked, material) = state
      case message {
        Sign(request, reply) -> {
          let asked = [#(request.hash, request.scheme), ..asked]
          let material = [request.message, ..material]
          case left > 0 {
            True -> {
              let signature =
                rsa_sign(key, request.message, request.hash, request.scheme)
              process.send(reply, Ok(signature))
              actor.continue(#(left - 1, asked, [signature, ..material]))
            }
            False -> {
              process.send(reply, Error(Nil))
              actor.continue(#(0, asked, material))
            }
          }
        }
        Asked(reply) -> {
          process.send(reply, list.reverse(asked))
          actor.continue(state)
        }
        Material(reply) -> {
          process.send(reply, material)
          actor.continue(state)
        }
      }
    })
    |> actor.start
  started.data
}

fn asked(
  key: process.Subject(KeyMessage),
) -> List(#(client_identity.Hash, client_identity.RsaScheme)) {
  process.call(key, 1000, Asked)
}

fn signer_identity(
  key: process.Subject(KeyMessage),
) -> client_identity.Identity {
  // The signer bounds its own wait below the connect timeout.
  let sign = fn(request) { process.call(key, 1000, Sign(request, _)) }
  let assert Ok(identity) =
    client_identity.from_signer(
      pem("a-chain.crt"),
      client_identity.RsaSigner(sign),
    )
  identity
}

fn signer_client(
  protocol: Protocol,
  identity: client_identity.Identity,
) -> http_gun.Client {
  let assert Ok(client) =
    settings()
    |> config.with_protocol(http_protocol(protocol))
    |> config.with_client_identity(identity)
    |> http_gun.start
  client
}

fn signer_schemes() {
  list.each(
    [
      #(H1Tls12Pkcs1, client_identity.Sha512, False),
      #(H1Tls12, client_identity.Sha512, True),
      #(H1, client_identity.Sha512, True),
      #(H2, client_identity.Sha512, True),
    ],
    fn(row) {
      let #(protocol, expected_hash, pss) = row
      let #(port, peer) = server(protocol)
      let key = key_holder("a.key", 10)
      let client = signer_client(protocol, signer_identity(key))
      let assert Ok(Receipt("a", _)) = fetch(client, req(port))
      let _ = await_request()
      // One handshake signs once. Over HTTP/2 the pool can open further
      // connections to the origin until the first one receives the server's
      // SETTINGS, and each of those handshakes signs too.
      let requests = asked(key)
      let assert True = case protocol {
        H2 -> requests != []
        _ -> list.length(requests) == 1
      }
      list.each(requests, fn(request) {
        let #(hash, scheme) = request
        let assert True = hash == expected_hash
        let assert True = case scheme, pss {
          client_identity.RsaPkcs1v15, False -> True
          client_identity.RsaPss(salt, mgf1), True -> mgf1 == hash && salt == 64
          _, _ -> False
        }
      })
      http_gun.stop(client)
      stop_server(peer)
    },
  )
  io.println(
    "PASS a signer process holds the key for PKCS#1 v1.5 and PSS over TLS 1.2 and 1.3",
  )
}

fn signer_reuse() {
  // Requests on an open connection never sign. OTP registers a TLS 1.2
  // session under the SNI name and looks it up by the connected address, so
  // a new connection to a named host signs again.
  let #(port, peer) = server(H1Tls12Resume)
  let key = key_holder("a.key", 10)
  let client = signer_client(H1Tls12Resume, signer_identity(key))
  let assert Ok(first) = fetch(client, req(port))
  let assert Ok(same) = fetch(client, req(port) |> request.set_path("/close"))
  let assert Ok(next) = fetch(client, req(port))
  let assert True = first.connection == same.connection
  let assert True = next.connection != first.connection
  let assert 3 = requests(0)
  let assert [_, _] = asked(key)
  // An IP literal sends no SNI, so the second connection resumes the session
  // and the server still sees the client certificate without a signature.
  let ip = fn(path) {
    req(port) |> request.set_host("127.0.0.1") |> request.set_path(path)
  }
  let assert Ok(first) = fetch(client, ip("/close"))
  let assert Ok(resumed) = fetch(client, ip("/"))
  let assert True = resumed.connection != first.connection
  let assert Receipt("a", _) = resumed
  let assert 2 = requests(0)
  let assert [_, _, _] = asked(key)
  http_gun.stop(client)
  stop_server(peer)
  // TLS 1.3: OTP offers no session resumption, so a new connection signs.
  let #(port, peer) = server(H1)
  let key = key_holder("a.key", 10)
  let client = signer_client(H1, signer_identity(key))
  let assert Ok(first) = fetch(client, req(port) |> request.set_path("/close"))
  let assert Ok(second) = fetch(client, req(port))
  let assert True = first.connection != second.connection
  let assert 2 = requests(0)
  let assert [_, _] = asked(key)
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS a signer signs per full handshake: not for reuse or a resumed session",
  )
}

fn signer_failures() {
  list.each([H1Tls12, H1], fn(protocol) {
    let #(port, peer) = server(protocol)
    let refusing = key_holder("a.key", 0)
    let assert Ok(panicking) =
      client_identity.from_signer(
        pem("a-chain.crt"),
        client_identity.RsaSigner(fn(_) { panic as "signer crashed" }),
      )
    list.each([signer_identity(refusing), panicking], fn(identity) {
      let client = signer_client(protocol, identity)
      let assert Error(failure) = http_gun.send(client, req(port))
      let assert error.ConnectionFailed(error.ClientSigningFailed) =
        error.reason(failure)
      let assert error.NotSent = error.evidence(failure)
      // The signer is the application's own; HTTP Gun never advises asking
      // it again.
      let assert error.Refused = error.kind(failure)
      let assert False = error.is_retryable(failure, idempotent: True)
      credentials_absent(error.describe(failure))
      http_gun.stop(client)
    })
    let assert [_] = asked(refusing)
    let assert 0 = requests(0)
    // A signature by a key that is not the certificate's is the server's
    // refusal, never a signing failure.
    let wrong = key_holder("wrong.key", 10)
    let client = signer_client(protocol, signer_identity(wrong))
    let assert Error(failure) = http_gun.send(client, req(port))
    let assert True = case error.reason(failure) {
      error.ConnectionFailed(error.CertificateRejected)
      | error.ConnectionFailed(error.TlsFailed)
      | error.RequestFailed(error.CertificateRejected)
      | error.RequestFailed(error.TlsFailed) -> True
      _ -> False
    }
    let assert [_] = asked(wrong)
    let assert 0 = requests(0)
    http_gun.stop(client)
    stop_server(peer)
  })
  let assert Error(client_identity.InvalidCertificateChain) =
    client_identity.from_signer(
      "",
      client_identity.RsaSigner(fn(_) { Error(Nil) }),
    )
  io.println(
    "PASS a refusing or crashing signer is ClientSigningFailed, Refused and not retryable; a wrong key is the server's refusal",
  )
}

fn signer_renegotiation() {
  let #(port, peer) = server(H1Tls12)
  let key = key_holder("a.key", 10)
  let client = signer_client(H1Tls12, signer_identity(key))
  let renegotiate = req(port) |> request.set_path("/renegotiate")
  let assert Ok(Receipt("a", _)) = fetch(client, renegotiate)
  let assert 1 = requests(0)
  let assert [_, _] = asked(key)
  http_gun.stop(client)
  // A refusal during renegotiation follows a sent request. OTP closes the
  // connection without telling its owner, so only the request's own timeout
  // ends the exchange.
  let once = key_holder("a.key", 1)
  let assert Ok(client) =
    settings()
    |> config.with_client_identity(signer_identity(once))
    |> http_gun.start
  let client = http_gun.with_timeout(client, duration.milliseconds(500))
  let assert Error(failure) = http_gun.send(client, renegotiate)
  let assert error.DeadlineExceeded = error.reason(failure)
  let assert error.MaybeSent = error.evidence(failure)
  credentials_absent(error.describe(failure))
  let assert 1 = requests(0)
  let assert [_, _] = asked(once)
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS a TLS 1.2 renegotiation signs again; its refusal ends at the request timeout",
  )
}

fn signer_connect_timeout() {
  let #(port, peer) = server(H1)
  let assert Ok(identity) =
    client_identity.from_signer(
      pem("a-chain.crt"),
      client_identity.RsaSigner(fn(_) {
        process.sleep(1000)
        Error(Nil)
      }),
    )
  let assert Ok(client) =
    settings()
    |> config.with_connect_timeout(duration.milliseconds(200))
    |> config.with_client_identity(identity)
    |> http_gun.start
  let assert Error(failure) = http_gun.send(client, req(port))
  let assert error.ConnectTimeout = error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert 0 = requests(0)
  http_gun.stop(client)
  stop_server(peer)
  io.println(
    "PASS the connect timeout bounds the opening handshake, not the signer",
  )
}

fn signer_leaves_no_trace() {
  let #(port, peer) = server(H1Tls12)
  capture_logs()
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      process.send(events, string.inspect(#(time, metadata)))
    })
  // One signed handshake, then one refused on the next connection.
  let key = key_holder("a.key", 1)
  let assert Ok(recorded) =
    cassette.record(
      settings() |> config.with_client_identity(signer_identity(key)),
      path("signer.json"),
      cassette.options(),
    )
  let assert Ok(Receipt("a", _)) =
    fetch(recorded.client, req(port) |> request.set_path("/close"))
  let assert Error(Http(failure)) = fetch(recorded.client, req(port))
  let assert error.ConnectionFailed(error.ClientSigningFailed) =
    error.reason(failure)
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(1))
  http_gun.stop(recorded.client)
  let assert Ok(_) = sinal.detach(attachment)
  let _ = await_request()
  // Two messages and one signature, none of which may appear anywhere.
  let material = process.call(key, 1000, Material)
  let assert 3 = list.length(material)
  let #(log_events, leaked) = logged(material)
  let assert True = log_events > 0
  let assert False = leaked
  let assert Ok(recording) = simplifile.read_bits(path("signer.json"))
  let texts =
    [error.describe(failure), error.name(failure), ..drain(events, [])]
    |> list.map(bit_array.from_string)
  let assert True = list.length(texts) > 2
  list.each(material, fn(bytes) {
    let encoded = bit_array.from_string(bit_array.base64_encode(bytes, True))
    list.each([recording, ..texts], fn(text) {
      let assert False = contains(text, bytes)
      let assert False = contains(text, encoded)
    })
  })
  stop_server(peer)
  io.println(
    "PASS logs, observations, failures and cassettes hold no signed message or signature",
  )
}

fn drain(events: process.Subject(String), seen: List(String)) -> List(String) {
  case process.receive(events, 0) {
    Ok(event) -> drain(events, [event, ..seen])
    Error(_) -> seen
  }
}
