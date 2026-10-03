//// Values HTTP Gun stores and returns (failures, observations, scripts,
//// cassettes, recordings and pool state) must not carry credential header
//// values, configured redacted headers or redacted query values, so that
//// `string.inspect`, crash reports and logs cannot print them.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/redaction
import http_gun/telemetry
import http_gun/testing
import simplifile
import sinal
import sinal/forwarder

const secrets = [
  "secret-authorization", "secret-proxy", "secret-cookie", "secret-set-cookie",
  "secret-signature", "secret-token",
]

fn redacting() -> redaction.Redaction {
  redaction.default()
  |> redaction.with_headers(["x-signature"])
  |> redaction.with_query_parameters(["token"])
}

fn with_credentials(
  req: request.Request(BitArray),
) -> request.Request(BitArray) {
  req
  |> request.set_header("authorization", "Bearer secret-authorization")
  |> request.set_header("proxy-authorization", "Basic secret-proxy")
  |> request.set_header("cookie", "session=secret-cookie")
  |> request.set_header("x-signature", "secret-signature")
}

fn assert_no_secret(value: a) -> Nil {
  let text = string.inspect(value)
  list.each(secrets, fn(secret) {
    string.contains(text, secret) |> should.be_false
  })
}

fn offline_request() -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://offline.invalid/resource?q=1&token=secret-token")
  request.set_body(req, <<"payload":utf8>>) |> with_credentials
}

pub fn failures_do_not_carry_request_credentials_test() {
  // Refused before submission: a private literal under the default policy.
  let assert Ok(private) =
    request.to("http://10.0.0.1/resource?token=secret-token")
  let private = request.set_body(private, <<>>) |> with_credentials
  let assert Ok(client) =
    http_gun.start(config.default() |> config.with_redaction(redacting()))
  let assert Error(rejected) = http_gun.send(client, private)
  let assert error.DestinationRejected(_) = error.reason(rejected)
  assert_no_secret(rejected)
  assert_no_secret(error.describe(rejected))

  // Invalid header beside credential headers.
  let invalid = private |> request.set_header("x-bad", "a\r\nb")
  let assert Error(invalid_failure) = http_gun.send(client, invalid)
  assert_no_secret(invalid_failure)
  http_gun.stop(client)

  // Playback mismatch and exhaustion.
  let exchange =
    testing.exchange(
      offline_request(),
      testing.Respond(response.Response(200, [], [<<>>]), testing.Finished([])),
    )
  let assert Ok(script) =
    testing.playback(
      testing.script([exchange]),
      config.default() |> config.with_redaction(redacting()),
    )
  let assert Error(mismatch) =
    http_gun.send(script, request.set_path(offline_request(), "/other"))
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(0))
  assert_no_secret(mismatch)
  let assert Ok(_) = http_gun.send(script, offline_request())
  let assert Error(exhausted) = http_gun.send(script, offline_request())
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  assert_no_secret(exhausted)
  http_gun.stop(script)
}

pub fn observations_do_not_carry_request_credentials_test() {
  let fwd =
    forwarder.new(process.new_name("http-gun-secret-observations"))
    |> forwarder.with_capacity(32)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      process.send(events, #(time, metadata))
    })
  let exchange =
    testing.exchange(
      offline_request(),
      testing.Respond(
        response.Response(200, [#("set-cookie", "secret-set-cookie")], [<<>>]),
        testing.Finished([]),
      ),
    )
  let settings =
    config.default()
    |> config.with_observations(fwd)
    |> config.with_redaction(redacting())
  let assert Ok(client) = testing.playback(testing.script([exchange]), settings)
  let assert Ok(_) = http_gun.send(client, offline_request())
  let seen = receive_events(events, 4)
  list.length(seen) |> should.equal(4)
  assert_no_secret(seen)
  http_gun.stop(client)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
}

pub fn scripted_exchange_drops_credential_headers_test() {
  let exchange =
    testing.exchange(
      offline_request(),
      testing.Respond(response.Response(200, [], [<<1>>]), testing.Finished([])),
    )
  let script = testing.script([exchange])
  // Credential headers are gone from the in-memory value.
  let text = string.inspect(script)
  list.each(
    ["secret-authorization", "secret-proxy", "secret-cookie"],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  list.map(testing.request(exchange).headers, fn(header) { header.0 })
  |> should.equal(["x-signature"])
  // The script still answers the credential-bearing request.
  let assert Ok(client) = testing.playback(script, config.default())
  let assert Ok(reply) = http_gun.send(client, offline_request())
  reply.response.body |> should.equal(<<1>>)
  http_gun.stop(client)
}

pub fn redaction_headers_drops_a_configured_header_list_test() {
  let headers = [
    #("Authorization", "a"),
    #("X-Signature", "b"),
    #("x-request-signature", "c"),
    #("accept", "d"),
    #("Set-Cookie", "e"),
    #("X-Trace", "f"),
  ]
  redaction.headers(redaction.default(), headers)
  |> should.equal([
    #("X-Signature", "b"),
    #("x-request-signature", "c"),
    #("accept", "d"),
    #("X-Trace", "f"),
  ])
  redaction.default()
  |> redaction.with_headers(["x-signature", "X-TRACE"])
  |> redaction.headers(headers)
  |> should.equal([#("x-request-signature", "c"), #("accept", "d")])
}

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "erlang", "element")
fn client_subject(index: Int, client: http_gun.Client) -> process.Subject(a)

@external(erlang, "sys", "get_state")
fn get_state(pid: process.Pid) -> Dynamic

fn queued(client: http_gun.Client, expected: Int, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.queued_requests == expected {
        True -> True
        False -> {
          process.sleep(1)
          queued(client, expected, tries - 1)
        }
      }
    }
  }
}

pub fn queued_request_headers_stay_out_of_pool_state_test() {
  let port = persistent()
  let assert Ok(base) =
    request.to("http://localhost:" <> int.to_string(port) <> "/held")
  let base = request.set_body(base, <<>>)
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.allow_loopback
      |> config.with_max_open_bodies(1),
    )
  let assert Ok(held) = http_gun.open(client, base)
  let assert Ok(secret) =
    request.to(
      "http://localhost:" <> int.to_string(port) <> "/queued?token=secret-token",
    )
  let secret =
    secret
    |> request.set_body(<<>>)
    |> request.set_header("authorization", "Bearer secret-authorization")
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(done, http_gun.send(client, secret))
    })
  queued(client, 1, 2000) |> should.be_true
  // The pool's state, as `sys:get_state` and crash reports would print it.
  let assert Ok(pool) = process.subject_owner(client_subject(2, client))
  let state = get_state(pool)
  let text = string.inspect(state)
  // The state is the real pool state: it holds the waiting entry and its
  // origin, but not the request's headers or query.
  string.contains(text, "Pending(") |> should.be_true
  string.contains(text, "localhost") |> should.be_true
  assert_no_secret(state)
  body.close(held.body)
  let assert Ok(Ok(reply)) = process.receive(done, 2000)
  reply.response.status |> should.equal(200)
  http_gun.stop(client)
}

pub fn encoded_and_parsed_cassettes_omit_credentials_test() {
  let exchange =
    testing.exchange(
      offline_request(),
      testing.Respond(
        response.Response(200, [#("set-cookie", "secret-set-cookie")], [<<1>>]),
        testing.Finished([#("set-cookie", "secret-set-cookie")]),
      ),
    )
  let text = cassette.encode(testing.script([exchange]))
  list.each(
    [
      "secret-authorization",
      "secret-proxy",
      "secret-cookie",
      "secret-set-cookie",
    ],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  let assert Ok(parsed) = cassette.parse(text, 1_000_000)
  // The parsed cassette still replays the credential-bearing request.
  let assert Ok(client) = testing.playback(parsed, config.default())
  let assert Ok(reply) = http_gun.send(client, offline_request())
  reply.response.body |> should.equal(<<1>>)
  http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "serve")
fn serve(response: BitArray) -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

pub fn live_recording_omits_credentials_and_configured_secrets_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nSet-Cookie: id=secret-set-cookie\r\nX-Signature: secret-signature\r\nContent-Length: 2\r\n\r\nok":utf8,
    >>)
  let destination = temp_path()
  let settings =
    config.default()
    |> config.allow_loopback
    |> config.with_redaction(redacting())
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let assert Ok(req) =
    request.to(
      "http://localhost:"
      <> int.to_string(port)
      <> "/resource?token=secret-token&q=1",
    )
  let req = request.set_body(req, <<>>) |> with_credentials
  let assert Ok(live) = http_gun.send(recorded.client, req)
  live.response.status |> should.equal(200)
  cassette.finish(recorded.recording, duration.milliseconds(5000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(text) = simplifile.read(destination)
  assert_no_secret(text)
  string.contains(text, "token=REDACTED&q=1") |> should.be_true
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
