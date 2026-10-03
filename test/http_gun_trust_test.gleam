import gleam/http/request
import gleam/int
import gleam/list
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error

@external(erlang, "http_gun_tls_test_server", "anchors")
fn anchors(name: String) -> List(BitArray)

@external(erlang, "http_gun_tls_test_server", "start")
fn server() -> Int

fn settings(trust: config.Trust) -> config.Config {
  config.default()
  |> config.allow_loopback
  |> config.with_trust(trust)
}

pub fn main() {
  memory_anchors_verify_local_tls_test()
  memory_anchors_keep_name_checks_and_isolate_trust_test()
  invalid_memory_anchors_fail_closed_test()
}

pub fn memory_anchors_keep_name_checks_and_isolate_trust_test() {
  list.each(
    [#("wrong.invalid", anchors("ca")), #("localhost", anchors("ip_ca"))],
    fn(test_case) {
      let assert Ok(client) =
        http_gun.start(
          settings(config.Anchors(test_case.1))
          |> config.with_resolver(fn(_, _) {
            Ok([destination.Ipv4(127, 0, 0, 1)])
          }),
        )
      let assert Ok(req) =
        request.to("https://" <> test_case.0 <> ":" <> int.to_string(server()))
      let outcome = http_gun.send(client, request.set_body(req, <<>>))
      http_gun.stop(client)
      outcome
      |> should.equal(
        Error(error.new(
          error.ConnectionFailed(error.CertificateRejected),
          error.NotSent,
        )),
      )
    },
  )
}

pub fn invalid_memory_anchors_fail_closed_test() {
  list.each(
    [
      #([], config.EmptyTrustAnchors),
      #([<<>>], config.InvalidTrustAnchor),
      #([<<1:size(1)>>], config.InvalidTrustAnchor),
    ],
    fn(row) {
      let c = settings(config.Anchors(row.0))
      config.validate(c) |> should.equal(Error(row.1))
      http_gun.start(c) |> should.equal(Error(http_gun.InvalidConfig(row.1)))
    },
  )
  let assert Ok(client) =
    http_gun.start(settings(config.Anchors([<<1, 2, 3>>])))
  let assert Ok(req) =
    request.to("https://localhost:" <> int.to_string(server()))
  let outcome = http_gun.send(client, request.set_body(req, <<>>))
  http_gun.stop(client)
  let assert Error(failure) = outcome
  error.evidence(failure) |> should.equal(error.NotSent)
}

pub fn memory_anchors_verify_local_tls_test() {
  let assert Ok(client) =
    http_gun.start(settings(config.Anchors(anchors("ca"))))
  let assert Ok(req) =
    request.to("https://localhost:" <> int.to_string(server()))
  let result = http_gun.send(client, request.set_body(req, <<>>))
  http_gun.stop(client)
  let assert Ok(reply) = result
  reply.response.body |> should.equal(<<"abc":utf8>>)
}
