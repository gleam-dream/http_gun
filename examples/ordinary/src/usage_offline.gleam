//// Offline use: scripted playback, mismatch and exhaustion, verification, a
//// failure that
//// keeps its response head, and cassette redaction.

import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import http_gun
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/redaction
import http_gun/testing

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

pub fn main() -> Nil {
  scripted()
  retry_after()
  redacted_cassette()
}

// A script answers requests in order; playback never opens a connection.
fn scripted() -> Nil {
  let assert Ok(expected) = request.to("https://api.example.test/orders")
  let expected = request.set_body(expected, <<>>)
  let script =
    testing.script([
      testing.exchange(
        expected,
        testing.Respond(
          response.new(200) |> response.set_body([<<"{\"ok\":true}":utf8>>]),
          testing.Finished([]),
        ),
      ),
    ])
  let assert Ok(client) = testing.playback(script, config.default())

  // A different request fails with its position and keeps the exchange.
  let assert Ok(other) = request.to("https://api.example.test/customers")
  let assert Error(mismatch) =
    http_gun.send(client, request.set_body(other, <<>>))
  let assert error.PlaybackMismatch(0) = error.reason(mismatch)

  let assert Ok(buffered) = http_gun.send(client, expected)
  let assert <<"{\"ok\":true}":utf8>> = buffered.response.body

  // A request after the last exchange fails as exhausted.
  let assert Error(exhausted) = http_gun.send(client, expected)
  let assert error.PlaybackExhausted = error.reason(exhausted)
  http_gun.stop(client)
  verified()
}

// Code under test may handle a playback failure as one more provider error.
// `verify` reports every request that missed and every exchange left, so the
// test fails on a stale or half-used script anyway.
fn verified() -> Nil {
  let assert Ok(expected) = request.to("https://api.example.test/orders")
  let expected = request.set_body(expected, <<>>)
  let reply =
    testing.Respond(
      response.new(204) |> response.set_body([]),
      testing.Finished([]),
    )
  let first = testing.exchange(expected, reply)
  let second = testing.exchange(expected, reply)
  let assert Ok(client) =
    testing.playback(testing.script([first, second]), config.default())
  let stale = request.set_path(expected, "/v2/orders")

  // snips-start: verify-playback
  // The code under test swallows the mismatch.
  let _ = http_gun.send(client, stale)
  let _ = http_gun.send(client, expected)

  let assert Ok(testing.Verdict(
    mismatched: [testing.Mismatch(position: 0, expected: _, actual: missed)],
    exhausted: [],
    unused: [_second],
  )) = testing.verify(client)
  let assert "/v2/orders" = missed.path
  http_gun.stop(client)
  // snips-end: verify-playback
}

// A failure after the head arrived keeps the status and the headers, so a
// rate-limit reply still says when to retry. Credential headers are redacted.
fn retry_after() -> Nil {
  let req = request.new() |> request.set_body(<<>>)
  let reply =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body([<<"too large":utf8>>])
  let script =
    testing.script([
      testing.exchange(req, testing.Respond(reply, testing.Finished([]))),
    ])
  let assert Ok(client) = testing.playback(script, config.default())
  let assert Error(failure) =
    http_gun.send(client |> http_gun.with_body_limit(4, http_gun.Fail), req)
  let assert Some(429) = error.status(failure)
  let assert Ok("30") = list.key_find(error.headers(failure), "retry-after")
  http_gun.stop(client)
}

// Recording stores the redacted form; playback applies the same redaction to
// both sides before matching, so the cassette still matches its recorder.
fn redacted_cassette() -> Nil {
  let port = server()
  let path = temp_path()
  let scrub =
    redaction.default()
    |> redaction.with_headers(["x-signature"])
    |> redaction.with_query_parameters(["token"])
  let settings =
    config.default() |> config.allow_loopback |> config.with_redaction(scrub)
  let assert Ok(req) = request.to("http://127.0.0.1:" <> int.to_string(port))
  let req =
    req
    |> request.set_body(<<>>)
    |> request.set_query([#("token", "secret-value"), #("page", "2")])
    |> request.set_header("x-signature", "secret-signature")

  // snips-start: record-and-load
  let assert Ok(cassette.Recorded(client:, recording:)) =
    cassette.record(settings, path, cassette.options())
  let assert Ok(_) = http_gun.send(client, req)
  let assert Ok(_) = cassette.finish(recording, duration.seconds(5))
  http_gun.stop(client)

  let assert Ok(script) = cassette.load(path, 1_048_576)
  let encoded = cassette.encode(script)
  remove_fixture(path)
  let assert False = string.contains(encoded, "secret")
  let assert True = string.contains(encoded, "token=REDACTED&page=2")
  let assert Ok(replay) = testing.playback(script, settings)
  let assert Ok(buffered) = http_gun.send(replay, req)
  let assert <<"abc":utf8>> = buffered.response.body
  http_gun.stop(replay)
  // snips-end: record-and-load
}
