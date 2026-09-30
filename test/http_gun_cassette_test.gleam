import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/fixture
import http_gun/testing

fn req() -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://offline.invalid/test?q=one")
  request.set_body(req, <<0, 255>>)
}

pub fn strict_order_and_non_consuming_mismatch_test() {
  let first =
    fixture.Exchange(
      req(),
      fixture.Respond(response.Response(201, [], [<<1>>]), fixture.Complete([])),
    )
  let second =
    fixture.Exchange(
      req(),
      fixture.Respond(
        response.Response(429, [], [<<2>>]),
        fixture.Complete([#("x-end", "yes")]),
      ),
    )
  let assert Ok(client) = testing.start(config.default(), [first, second])
  let assert Error(failure) =
    http_gun.send(client, request.set_path(req(), "/wrong"))
  failure.reason |> should.equal(error.FixtureMismatch(0))
  let assert Ok(a) = http_gun.send(client, req())
  let assert Ok(b) = http_gun.send(client, req())
  a.response.status |> should.equal(201)
  b.response.body |> should.equal(<<2>>)
  b.trailers |> should.equal([#("x-end", "yes")])
  b.protocol |> should.equal(config.Offline)
  let assert Error(exhausted) = http_gun.send(client, req())
  exhausted.reason |> should.equal(error.FixtureExhausted)
  let _ = http_gun.stop(client)
}

pub fn binary_codec_roundtrip_and_strict_errors_test() {
  let exchange =
    fixture.Exchange(
      req(),
      fixture.Respond(
        response.Response(503, [#("x-two", "a"), #("x-two", "b")], [
          <<0, 255, 128>>,
        ]),
        fixture.Complete([#("x-end", "yes")]),
      ),
    )
  let assert Ok(value) = cassette.new([exchange])
  let text = cassette.encode(value)
  let assert Ok(decoded) = cassette.parse(text, 10_000)
  cassette.encode(decoded) |> should.equal(text)
  let assert Error(version) =
    cassette.parse("{\"http_gun\":42,\"exchanges\":[]}", 10_000)
  version.reason |> should.equal(error.FixtureVersion(42))
  let assert Error(corrupt) = cassette.parse("{}", 10_000)
  corrupt.reason |> should.equal(error.FixtureCorrupt)
  let assert Error(missing) = cassette.load("/no/http-gun-fixture-here", 10_000)
  missing.reason |> should.equal(error.FixtureMissing)
}

pub fn failure_before_headers_releases_admission_test() {
  let rejection =
    fixture.Exchange(
      req(),
      fixture.Reject(error.Failure(error.ConnectionFailed, error.NotSubmitted)),
    )
  let c = config.default()
  let assert Ok(client) =
    testing.start(
      config.Config(
        ..c,
        deadline_ms: 100,
        limits: config.Limits(..c.limits, active: 1),
      ),
      [rejection, rejection],
    )
  let assert Error(first) = http_gun.send(client, req())
  let assert Error(second) = http_gun.send(client, req())
  first.reason |> should.equal(error.ConnectionFailed)
  second.reason |> should.equal(error.ConnectionFailed)
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_scope_test_ffi", "fixture")
fn store(contents: String) -> String

@external(erlang, "http_gun_scope_test_ffi", "remove")
fn remove(path: String) -> Nil

pub fn real_disk_offline_and_header_matching_test() {
  let expected =
    req()
    |> request.set_header("authorization", "secret-one")
    |> request.set_header("x-api-key", "secret-three")
    |> request.set_header("api-key", "secret-four")
    |> request.set_header("x-goog-api-key", "secret-five")
    |> request.set_header("accept", "application/octet-stream")
  let item =
    fixture.Exchange(
      expected,
      fixture.Respond(
        response.Response(200, [#("set-cookie", "secret-two")], [<<0, 255>>]),
        fixture.Complete([]),
      ),
    )
  let assert Ok(value) = cassette.new([item])
  let text = cassette.encode(value)
  string.contains(text, "secret-one") |> should.be_false
  string.contains(text, "secret-two") |> should.be_false
  string.contains(text, "secret-three") |> should.be_false
  string.contains(text, "secret-four") |> should.be_false
  string.contains(text, "secret-five") |> should.be_false
  let path = store(text)
  let assert Ok(value) = cassette.load(path, 10_000)
  let assert Ok(client) = cassette.playback(value, config.default())
  let assert Error(mismatch) = http_gun.send(client, req())
  mismatch.reason |> should.equal(error.FixtureMismatch(0))
  let actual = expected |> request.set_header("authorization", "new-secret")
  let assert Ok(reply) = http_gun.send(client, actual)
  reply.response.body |> should.equal(<<0, 255>>)
  let _ = http_gun.stop(client)
  remove(path)
}

pub fn partial_byte_fixture_is_rejected_test() {
  let item =
    fixture.Exchange(
      req(),
      fixture.Respond(
        response.Response(200, [], [<<1:size(1)>>]),
        fixture.Complete([]),
      ),
    )
  let assert Error(failure) = cassette.new([item])
  failure.reason |> should.equal(error.FixtureCorrupt)
  testing.start(config.default(), [item]) |> should.be_error
}

pub fn disk_read_limit_is_exact_test() {
  let assert Ok(tape) = cassette.new([])
  let encoded = cassette.encode(tape)
  let size = string.byte_size(encoded)
  let path = store(encoded)
  cassette.load(path, size) |> should.be_ok
  let assert Error(too_large) = cassette.load(path, size - 1)
  too_large.reason |> should.equal(error.LimitExceeded("fixture", size - 1))
  let assert Error(negative) = cassette.load(path, -1)
  negative.reason |> should.equal(error.LimitExceeded("fixture", -1))
  remove(path)
  let empty = store("")
  let assert Error(corrupt) = cassette.load(empty, 0)
  corrupt.reason |> should.equal(error.FixtureCorrupt)
  remove(empty)
}

fn queued(client: http_gun.Client, expected: Int, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.snapshot(client)
      case stats.waiting == expected {
        True -> True
        False -> queued(client, expected, tries - 1)
      }
    }
  }
}

pub fn queued_playback_preserves_session_order_across_origins_test() {
  let requests = [
    request.set_host(req(), "z.invalid"),
    request.set_host(req(), "a.invalid"),
    request.set_host(req(), "z.invalid"),
  ]
  let exchanges =
    list.map([req(), ..requests], fn(r) {
      fixture.Exchange(
        r,
        fixture.Respond(
          response.Response(200, [], [<<0, 255>>]),
          fixture.Complete([]),
        ),
      )
    })
  let c = config.default()
  let assert Ok(client) =
    testing.start(
      config.Config(..c, limits: config.Limits(..c.limits, active: 1)),
      exchanges,
    )
  let assert Ok(held) = http_gun.open(client, req())
  let done = process.new_subject()
  let _ =
    list.fold(requests, 0, fn(count, r) {
      let _ =
        process.spawn_unlinked(fn() {
          process.send(done, http_gun.send(client, r))
        })
      queued(client, count + 1, 1000) |> should.be_true
      count + 1
    })
  body.close(held.body) |> should.be_ok
  list.each(requests, fn(_) {
    let assert Ok(Ok(reply)) = process.receive(done, 1000)
    reply.response.body |> should.equal(<<0, 255>>)
  })
  let assert Error(exhausted) = http_gun.send(client, req())
  exhausted.reason |> should.equal(error.FixtureExhausted)
  let _ = http_gun.stop(client)
}

import gleam/erlang/process
