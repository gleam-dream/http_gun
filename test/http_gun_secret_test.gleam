//// Values HTTP Gun stores and returns (failures, observations, cassettes and
//// recordings) must not carry credential header values, so that
//// `string.inspect`, crash reports and logs cannot print them.

import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/fixture
import http_gun/recording
import http_gun/telemetry
import http_gun/testing
import simplifile
import sinal
import sinal/forwarder

const secrets = [
  "secret-authorization", "secret-proxy", "secret-cookie", "secret-set-cookie",
]

fn with_credentials(
  req: request.Request(BitArray),
) -> request.Request(BitArray) {
  req
  |> request.set_header("authorization", "Bearer secret-authorization")
  |> request.set_header("proxy-authorization", "Basic secret-proxy")
  |> request.set_header("cookie", "session=secret-cookie")
}

fn assert_no_secret(value: a) -> Nil {
  let text = string.inspect(value)
  list.each(secrets, fn(secret) {
    string.contains(text, secret) |> should.be_false
  })
}

fn offline_request() -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://offline.invalid/resource?q=1")
  request.set_body(req, <<"payload":utf8>>) |> with_credentials
}

pub fn failures_do_not_carry_request_credentials_test() {
  // Refused before submission: a private literal under the default policy.
  let assert Ok(private) = request.to("http://10.0.0.1/resource")
  let private = request.set_body(private, <<>>) |> with_credentials
  let assert Ok(client) = http_gun.start(config.default())
  let assert Error(rejected) = http_gun.send(client, private)
  rejected.reason |> should.equal(error.DestinationRejected)
  assert_no_secret(rejected)

  // Invalid header beside credential headers.
  let invalid = private |> request.set_header("x-bad", "a\r\nb")
  let assert Error(invalid_failure) = http_gun.send(client, invalid)
  assert_no_secret(invalid_failure)
  let _ = http_gun.stop(client)

  // Playback mismatch and exhaustion.
  let exchange =
    fixture.Exchange(
      offline_request(),
      fixture.Respond(response.Response(200, [], [<<>>]), fixture.Complete([])),
    )
  let assert Ok(script) = testing.start(config.default(), [exchange])
  let assert Error(mismatch) =
    http_gun.send(script, request.set_path(offline_request(), "/other"))
  mismatch.reason |> should.equal(error.FixtureMismatch(0))
  assert_no_secret(mismatch)
  let assert Ok(_) = http_gun.send(script, offline_request())
  let assert Error(exhausted) = http_gun.send(script, offline_request())
  exhausted.reason |> should.equal(error.FixtureExhausted)
  assert_no_secret(exhausted)
  let _ = http_gun.stop(script)
}

pub fn observations_do_not_carry_request_credentials_test() {
  let assert Ok(fwd) =
    forwarder.new(process.new_name("http-gun-secret-observations"), 32)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  let events = process.new_subject()
  let assert Ok(id) = sinal.handler_id("http-gun-secret-observation")
  let assert Ok(attachment) =
    sinal.observe(id, telemetry.event(), fn(time, metadata) {
      process.send(events, #(time, metadata))
    })
  let exchange =
    fixture.Exchange(
      offline_request(),
      fixture.Respond(
        response.Response(200, [#("set-cookie", "secret-set-cookie")], [<<>>]),
        fixture.Complete([]),
      ),
    )
  let settings = config.Config(..config.default(), observations: Some(fwd))
  let assert Ok(client) = testing.start(settings, [exchange])
  let assert Ok(_) = http_gun.send(client, offline_request())
  let seen = receive_events(events, 4)
  list.length(seen) |> should.equal(4)
  assert_no_secret(seen)
  let _ = http_gun.stop(client)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
}

pub fn encoded_and_parsed_cassettes_omit_credentials_test() {
  let exchange =
    fixture.Exchange(
      offline_request(),
      fixture.Respond(
        response.Response(200, [#("set-cookie", "secret-set-cookie")], [<<1>>]),
        fixture.Complete([#("set-cookie", "secret-set-cookie")]),
      ),
    )
  let assert Ok(tape) = cassette.new([exchange])
  let text = cassette.encode(tape)
  assert_no_secret(text)
  let assert Ok(parsed) = cassette.parse(text, 1_000_000)
  assert_no_secret(parsed)
  // The parsed cassette still replays the credential-bearing request.
  let assert Ok(client) = cassette.playback(parsed, config.default())
  let assert Ok(reply) = http_gun.send(client, offline_request())
  reply.response.body |> should.equal(<<1>>)
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "serve")
fn serve(response: BitArray) -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

pub fn live_recording_omits_credentials_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nSet-Cookie: id=secret-set-cookie\r\nContent-Length: 2\r\n\r\nok":utf8,
    >>)
  let destination = temp_path()
  let settings = config.default() |> config.allow_loopback
  let assert Ok(recorded) =
    cassette.record(settings, destination, recording.default())
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/resource")
  let req = request.set_body(req, <<>>) |> with_credentials
  let assert Ok(live) = http_gun.send(recorded.client, req)
  live.response.status |> should.equal(200)
  recording.finish_wait(recorded.recording, 5000)
  |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(text) = simplifile.read(destination)
  assert_no_secret(text)
  let assert Ok(loaded) = cassette.load(destination, 1_000_000)
  assert_no_secret(loaded)
  remove(destination)
}

fn receive_events(
  subject: process.Subject(#(telemetry.Timing, telemetry.Metadata)),
  remaining: Int,
) -> List(#(telemetry.Timing, telemetry.Metadata)) {
  case remaining {
    0 -> []
    _ ->
      case process.receive(subject, 1000) {
        Ok(event) -> [event, ..receive_events(subject, remaining - 1)]
        Error(Nil) -> []
      }
  }
}
