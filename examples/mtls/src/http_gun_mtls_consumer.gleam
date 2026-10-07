//// Public mTLS consumer: application-owned credential input, native results,
//// independent trust, identity isolation, rotation and conservative recovery.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
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
  io.println("PASS mTLS public consumer: 12 native/admission/lifecycle groups")
}

fn authenticated(protocol: Protocol) {
  let #(port, peer) = server(protocol)
  let assert Ok(client) =
    settings()
    |> config.with_protocol(case protocol {
      H1 | H1Tls12 -> config.Http1
      H2 -> config.RequireHttp2
    })
    |> config.with_client_identity(case protocol {
      H1 | H1Tls12 -> {
        let assert Ok(rsa) =
          client_identity.from_pem(pem("a-chain.crt"), pem("a-rsa.key"))
        rsa
      }
      H2 -> identity("a")
    })
    |> http_gun.start
  let assert Ok(reply) = http_gun.send(client, req(port))
  let assert <<"a":utf8>> = reply.response.body
  let assert True =
    reply.protocol
    == case protocol {
      H1 | H1Tls12 -> config.H1
      H2 -> config.H2
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
