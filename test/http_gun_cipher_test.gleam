import gleam/http/request
import gleam/int
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_tls_test_server", "anchors")
fn anchors(name: String) -> List(BitArray)

@external(erlang, "http_gun_tls_test_server", "tls12_cbc_only")
fn tls12_cbc_only() -> Int

fn send(settings: config.Config) {
  let assert Ok(client) =
    http_gun.start(
      settings
      |> config.allow_loopback
      |> config.with_trust(config.Anchors(anchors("ca"))),
    )
  let assert Ok(req) =
    request.to("https://localhost:" <> int.to_string(tls12_cbc_only()))
  let outcome = http_gun.send(client, request.set_body(req, <<>>))
  http_gun.stop(client)
  outcome
}

/// OTP's defaults exclude CBC suites, so a server that accepts only one
/// refuses the handshake before any request byte is sent.
pub fn default_suites_cannot_reach_a_cbc_only_server_test() {
  let assert Error(failure) = send(config.default())
  error.evidence(failure) |> should.equal(error.NotSent)
}

/// Adding the TLS 1.2 ECDHE AES-CBC suites after the defaults reaches it,
/// with peer and host name verification unchanged.
pub fn tls12_cbc_suites_reach_a_cbc_only_server_test() {
  let assert Ok(buffered) =
    send(
      config.default()
      |> config.with_cipher_suites(config.OtpDefaultsAndTls12Cbc),
    )
  buffered.response.status |> should.equal(200)
  buffered.response.body |> should.equal(<<"abc">>)
}

pub fn default_is_otp_defaults_test() {
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.with_cipher_suites(config.OtpDefaults)
      |> config.allow_loopback
      |> config.with_trust(config.Anchors(anchors("ca"))),
    )
  http_gun.stop(client)
}
