import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
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
  let c = config.default()
  config.Config(
    ..c,
    trust:,
    destination: destination.Policy(..c.destination, allow_loopback: True),
  )
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
      let c = settings(config.Anchors(test_case.1))
      let assert Ok(client) =
        http_gun.start(
          config.Config(
            ..c,
            destination: destination.Policy(
              ..c.destination,
              resolver: Some(fn(_, _) { Ok([destination.Ipv4(127, 0, 0, 1)]) }),
            ),
          ),
        )
      let assert Ok(req) =
        request.to("https://" <> test_case.0 <> ":" <> int.to_string(server()))
      let outcome = http_gun.send(client, request.set_body(req, <<>>))
      let _ = http_gun.stop(client)
      outcome
      |> should.equal(
        Error(error.Failure(
          error.ConnectionFailed(error.CertificateRejected),
          error.NotSubmitted,
        )),
      )
    },
  )
}

pub fn invalid_memory_anchors_fail_closed_test() {
  list.each([[], [<<>>], [<<1:size(1)>>]], fn(certs) {
    let c = settings(config.Anchors(certs))
    config.validate(c) |> should.be_error
    let assert Error(error.Failure(error.InvalidConfig(_), error.NotSubmitted)) =
      http_gun.start(c)
  })
  let assert Ok(client) =
    http_gun.start(settings(config.Anchors([<<1, 2, 3>>])))
  let assert Ok(req) =
    request.to("https://localhost:" <> int.to_string(server()))
  let outcome = http_gun.send(client, request.set_body(req, <<>>))
  let _ = http_gun.stop(client)
  let assert Error(error.Failure(_, error.NotSubmitted)) = outcome
}

pub fn memory_anchors_verify_local_tls_test() {
  let assert Ok(client) =
    http_gun.start(settings(config.Anchors(anchors("ca"))))
  let assert Ok(req) =
    request.to("https://localhost:" <> int.to_string(server()))
  let result = http_gun.send(client, request.set_body(req, <<>>))
  let _ = http_gun.stop(client)
  let assert Ok(reply) = result
  reply.response.body |> should.equal(<<"abc":utf8>>)
}
