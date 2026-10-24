import gleam/bit_array
import gleam/dict
import gleam/dynamic/decode
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/testing

fn req() -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://offline.invalid/test?q=one")
  request.set_body(req, <<0, 255>>)
}

fn respond(
  status: Int,
  headers: List(#(String, String)),
  chunks: List(BitArray),
  trailers: List(#(String, String)),
) -> testing.Reply {
  testing.Respond(
    response.Response(status, headers, chunks),
    testing.Finished(trailers),
  )
}

pub fn strict_order_and_non_consuming_mismatch_test() {
  let first = testing.exchange(req(), respond(201, [], [<<1>>], []))
  let second =
    testing.exchange(req(), respond(429, [], [<<2>>], [#("x-end", "yes")]))
  let assert Ok(client) =
    testing.playback(testing.script([first, second]), config.default())
  let assert Error(failure) =
    http_gun.send(client, request.set_path(req(), "/wrong"))
  error.reason(failure) |> should.equal(error.PlaybackMismatch(0))
  let assert Ok(a) = http_gun.send(client, req())
  let assert Ok(b) = http_gun.send(client, req())
  a.response.status |> should.equal(201)
  b.response.body |> should.equal(<<2>>)
  b.trailers |> should.equal([#("x-end", "yes")])
  b.protocol |> should.equal(config.Offline)
  let assert Error(exhausted) = http_gun.send(client, req())
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}

pub fn binary_codec_roundtrip_and_strict_errors_test() {
  let exchange =
    testing.exchange(
      req(),
      respond(503, [#("x-two", "a"), #("x-two", "b")], [<<0, 255, 128>>], [
        #("x-end", "yes"),
      ]),
    )
  let text = cassette.encode(testing.script([exchange]))
  let assert Ok(decoded) = cassette.parse(text, 10_000)
  cassette.encode(decoded) |> should.equal(text)
  testing.exchanges(decoded) |> should.equal([exchange])
  cassette.parse("{\"http_gun\":42,\"exchanges\":[]}", 10_000)
  |> should.equal(Error(cassette.UnsupportedVersion(42)))
  cassette.parse("{}", 10_000) |> should.equal(Error(cassette.Corrupt))
  cassette.load("/no/http-gun-fixture-here", 10_000)
  |> should.equal(Error(cassette.Missing))
}

fn chunks_decoder() -> decode.Decoder(List(dict.Dict(String, String))) {
  decode.at(
    ["reply", "chunks"],
    decode.list(decode.dict(decode.string, decode.string)),
  )
}

pub fn schema_two_stores_text_and_base64_chunks_test() {
  let text_chunk = <<"héllo, wörld\n":utf8>>
  let control_chunk = <<0, 1, 2>>
  let binary_chunk = <<0, 255, 128>>
  let invalid_utf8_chunk = <<"ab":utf8, 0xC3>>
  let text_request =
    req() |> request.set_body(<<"{\"name\":\"ünïcode\"}":utf8>>)
  let binary_request = req() |> request.set_body(<<0xFF, 0xFE>>)
  let exchanges = [
    testing.exchange(
      text_request,
      respond(
        200,
        [],
        [text_chunk, binary_chunk, control_chunk, invalid_utf8_chunk],
        [],
      ),
    ),
    testing.exchange(binary_request, respond(204, [], [], [])),
  ]
  let text = cassette.encode(testing.script(exchanges))

  // The stored schema: version 2, readable text where the bytes are UTF-8.
  json.parse(text, decode.at(["http_gun"], decode.int)) |> should.equal(Ok(2))
  let assert Ok(stored_chunks) =
    json.parse(text, decode.at(["exchanges"], decode.list(chunks_decoder())))
  stored_chunks
  |> should.equal([
    [
      dict.from_list([#("text", "héllo, wörld\n")]),
      dict.from_list([#("base64", bit_array.base64_encode(binary_chunk, True))]),
      dict.from_list([#("text", "\u{0000}\u{0001}\u{0002}")]),
      dict.from_list([
        #("base64", bit_array.base64_encode(invalid_utf8_chunk, True)),
      ]),
    ],
    [],
  ])
  let assert Ok(bodies) =
    json.parse(
      text,
      decode.at(
        ["exchanges"],
        decode.list(decode.at(
          ["request", "body"],
          decode.dict(decode.string, decode.string),
        )),
      ),
    )
  bodies
  |> should.equal([
    dict.from_list([#("text", "{\"name\":\"ünïcode\"}")]),
    dict.from_list([
      #("base64", bit_array.base64_encode(<<0xFF, 0xFE>>, True)),
    ]),
  ])
  // Text stays readable in the file itself.
  string.contains(text, "wörld") |> should.be_true

  // Exact bytes round trip through the file and through playback.
  let assert Ok(parsed) = cassette.parse(text, 100_000)
  testing.exchanges(parsed) |> should.equal(exchanges)
  let assert Ok(client) = testing.playback(parsed, config.default())
  let assert Ok(response) = http_gun.open(client, text_request)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(text_chunk))))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(binary_chunk))))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(control_chunk))))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(invalid_utf8_chunk))))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.End([]))))
  body.close(response.body)
  let assert Ok(empty) = http_gun.send(client, binary_request)
  empty.response.status |> should.equal(204)
  empty.response.body |> should.equal(<<>>)
  http_gun.stop(client)
}

pub fn version_one_cassette_is_unsupported_test() {
  let version_one =
    "{\"http_gun\":1,\"exchanges\":[{\"request\":{\"method\":\"GET\",\"url\":\"http://offline.invalid/\",\"headers\":[],\"body\":\"\"},\"reply\":{\"kind\":\"response\",\"status\":200,\"headers\":[],\"chunks\":[\"AP8=\"],\"ending\":{\"kind\":\"complete\",\"trailers\":[]}}}]}"
  cassette.parse(version_one, 10_000)
  |> should.equal(Error(cassette.UnsupportedVersion(1)))
  let path = store(version_one)
  cassette.load(path, 10_000)
  |> should.equal(Error(cassette.UnsupportedVersion(1)))
  remove(path)
}

pub fn corrupt_and_too_large_cassettes_are_rejected_test() {
  let valid =
    cassette.encode(
      testing.script([
        testing.exchange(req(), respond(200, [], [<<"ok":utf8>>], [])),
      ]),
    )
  let corrupt = [
    "not JSON",
    "",
    "[]",
    "{}",
    "{\"http_gun\":\"2\",\"exchanges\":[]}",
    "{\"http_gun\":2}",
    "{\"http_gun\":2,\"exchanges\":{}}",
    // A chunk that is neither text nor base64.
    string.replace(valid, "{\"text\":\"ok\"}", "{\"hex\":\"6f6b\"}"),
    // Invalid base64.
    string.replace(valid, "{\"text\":\"ok\"}", "{\"base64\":\"!!\"}"),
    // A chunk stored as a bare base64 string, as schema 1 did.
    string.replace(valid, "{\"text\":\"ok\"}", "\"b2s=\""),
    // A status outside 200..599.
    string.replace(valid, "\"status\":200", "\"status\":101"),
    // An unknown ending.
    string.replace(valid, "\"finished\"", "\"complete\""),
    // A truncated file.
    string.drop_end(valid, 3),
  ]
  // Every replacement above changed the cassette.
  list.count(corrupt, fn(text) { text == valid }) |> should.equal(0)
  list.each(corrupt, fn(text) {
    cassette.parse(text, 100_000) |> should.equal(Error(cassette.Corrupt))
  })
  cassette.parse(valid, 100_000) |> should.be_ok

  let size = string.byte_size(valid)
  cassette.parse(valid, size) |> should.be_ok
  cassette.parse(valid, size - 1)
  |> should.equal(Error(cassette.TooLarge(size - 1, size)))
  let path = store(valid)
  cassette.load(path, size) |> should.be_ok
  cassette.load(path, size - 1)
  |> should.equal(Error(cassette.TooLarge(size - 1, size)))
  remove(path)
  // A file that is not UTF-8 is corrupt.
  let binary = store_bytes(<<0xFF, 0xFE, 0xFD>>)
  cassette.load(binary, 100) |> should.equal(Error(cassette.Corrupt))
  remove(binary)
}

pub fn failure_before_headers_releases_admission_test() {
  let rejection =
    testing.exchange(
      req(),
      testing.Reject(error.new(
        error.ConnectionFailed(error.UnknownTransport),
        error.NotSent,
      )),
    )
  let assert Ok(client) =
    testing.playback(
      testing.script([rejection, rejection]),
      config.default()
        |> config.with_request_timeout(config.After(duration.milliseconds(100)))
        |> config.with_max_open_bodies(1),
    )
  let assert Error(first) = http_gun.send(client, req())
  let assert Error(second) = http_gun.send(client, req())
  error.reason(first)
  |> should.equal(error.ConnectionFailed(error.UnknownTransport))
  error.reason(second)
  |> should.equal(error.ConnectionFailed(error.UnknownTransport))
  http_gun.stop(client)
}

@external(erlang, "http_gun_scope_test_ffi", "fixture")
fn store(contents: String) -> String

@external(erlang, "http_gun_scope_test_ffi", "fixture")
fn store_bytes(contents: BitArray) -> String

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
    testing.exchange(
      expected,
      respond(200, [#("set-cookie", "secret-two")], [<<0, 255>>], []),
    )
  let text = cassette.encode(testing.script([item]))
  string.contains(text, "secret-one") |> should.be_false
  string.contains(text, "secret-two") |> should.be_false
  string.contains(text, "secret-three") |> should.be_false
  string.contains(text, "secret-four") |> should.be_false
  string.contains(text, "secret-five") |> should.be_false
  let path = store(text)
  let assert Ok(value) = cassette.load(path, 10_000)
  let assert Ok(client) = testing.playback(value, config.default())
  let assert Error(mismatch) = http_gun.send(client, req())
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(0))
  let actual = expected |> request.set_header("authorization", "new-secret")
  let assert Ok(reply) = http_gun.send(client, actual)
  reply.response.body |> should.equal(<<0, 255>>)
  http_gun.stop(client)
  remove(path)
}

pub fn partial_byte_fixture_is_rejected_test() {
  let item = testing.exchange(req(), respond(200, [], [<<1:size(1)>>], []))
  testing.playback(testing.script([item]), config.default())
  |> should.equal(Error(http_gun.InvalidScript(0)))
  let valid = testing.exchange(req(), respond(200, [], [<<1>>], []))
  testing.playback(testing.script([valid, item]), config.default())
  |> should.equal(Error(http_gun.InvalidScript(1)))
}

pub fn disk_read_limit_is_exact_test() {
  let encoded = cassette.encode(testing.script([]))
  let size = string.byte_size(encoded)
  let path = store(encoded)
  cassette.load(path, size) |> should.be_ok
  cassette.load(path, size - 1)
  |> should.equal(Error(cassette.TooLarge(size - 1, size)))
  // A negative limit admits nothing.
  cassette.load(path, -1) |> should.equal(Error(cassette.TooLarge(0, 1)))
  remove(path)
  cassette.load(path, 10_000) |> should.equal(Error(cassette.Missing))
  cassette.parse("not JSON", -1)
  |> should.equal(Error(cassette.TooLarge(0, 8)))
  let empty = store("")
  cassette.load(empty, 0) |> should.equal(Error(cassette.Corrupt))
  remove(empty)
}

fn queued(client: http_gun.Client, expected: Int, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.queued_requests == expected {
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
      testing.exchange(r, respond(200, [], [<<0, 255>>], []))
    })
  let assert Ok(client) =
    testing.playback(
      testing.script(exchanges),
      config.default() |> config.with_max_open_bodies(1),
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
  body.close(held.body)
  list.each(requests, fn(_) {
    let assert Ok(Ok(reply)) = process.receive(done, 1000)
    reply.response.body |> should.equal(<<0, 255>>)
  })
  let assert Error(exhausted) = http_gun.send(client, req())
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}

pub fn ignoring_headers_skips_named_headers_on_both_sides_test() {
  let expected =
    req()
    |> request.set_header("x-date", "2026-01-01")
    |> request.set_header("x-signature", "recorded")
    |> request.set_header("accept", "text/plain")
  let actual =
    req()
    |> request.set_header("X-Date", "2026-10-02")
    |> request.set_header("accept", "text/plain")
  let exchanges = [
    testing.exchange(expected, respond(200, [], [<<"one":utf8>>], [])),
    testing.exchange(expected, respond(200, [], [<<"two":utf8>>], [])),
  ]

  // Exact matching sees the changed headers.
  let assert Ok(exact) =
    testing.playback(testing.script(exchanges), config.default())
  let assert Error(mismatch) = http_gun.send(exact, actual)
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(0))
  http_gun.stop(exact)

  let script =
    testing.script(exchanges)
    |> testing.ignoring_headers(["X-Date"])
    |> testing.ignoring_headers(["x-signature"])
  let assert Ok(client) = testing.playback(script, config.default())
  let assert Ok(one) = http_gun.send(client, actual)
  one.response.body |> should.equal(<<"one":utf8>>)
  // Other headers still take part in matching, and a mismatch keeps the
  // exchange in place.
  let assert Error(other) =
    http_gun.send(client, request.set_header(actual, "accept", "text/html"))
  error.reason(other) |> should.equal(error.PlaybackMismatch(1))
  let assert Ok(two) =
    http_gun.send(client, request.set_header(actual, "x-date", "later"))
  two.response.body |> should.equal(<<"two":utf8>>)
  let assert Error(exhausted) = http_gun.send(client, actual)
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}

pub fn custom_matcher_replaces_the_comparison_test() {
  let seen = process.new_subject()
  let expected =
    req()
    |> request.set_header("Accept", "text/plain")
    |> request.set_header("authorization", "Bearer recorded")
  let script =
    testing.script([
      testing.exchange(expected, respond(200, [], [<<"first":utf8>>], [])),
      testing.exchange(expected, respond(201, [], [<<"second":utf8>>], [])),
    ])
    |> testing.ignoring_headers(["x-trace"])
    |> testing.matching(fn(expected, actual) {
      process.send(seen, #(expected, actual))
      expected.method == actual.method && expected.path == actual.path
    })
  let assert Ok(client) = testing.playback(script, config.default())

  // The matcher decides: a different query, body and headers still match.
  let actual =
    req()
    |> request.set_query([#("q", "two")])
    |> request.set_body(<<"other":utf8>>)
    |> request.set_header("X-Trace", "abc")
    |> request.set_header("Authorization", "Bearer live")
    |> request.set_header("x-extra", "yes")
  let assert Ok(first) = http_gun.send(client, actual)
  first.response.body |> should.equal(<<"first":utf8>>)
  // It receives the match_key forms: credentials removed, names lowercased,
  // ignored headers dropped.
  let assert Ok(#(given_expected, given_actual)) = process.receive(seen, 1000)
  given_expected.headers |> should.equal([#("accept", "text/plain")])
  given_actual.headers |> should.equal([#("x-extra", "yes")])
  given_expected.path |> should.equal("/test")

  // A refusal is a mismatch at the current position; the exchange stays.
  let assert Error(mismatch) =
    http_gun.send(client, request.set_path(actual, "/elsewhere"))
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(1))
  let assert Ok(second) = http_gun.send(client, actual)
  second.response.status |> should.equal(201)
  let assert Error(exhausted) = http_gun.send(client, actual)
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}

// ReqCassette sequence scenarios + Mint-style deterministic fragmentation.
pub fn generated_binary_sequences_preserve_every_exchange_test() {
  let bytes = int.range(0, 256, <<>>, fn(acc, byte) { <<acc:bits, byte>> })
  let exchanges =
    int.range(0, 65, [], fn(acc, at) {
      let split = at * 4
      let assert Ok(first) = bit_array.slice(bytes, 0, split)
      let assert Ok(last) = bit_array.slice(bytes, split, 256 - split)
      [
        testing.exchange(
          req(),
          respond(
            200 + at,
            [#("x-repeat", "a"), #("x-repeat", "b")],
            [first, last],
            [#("x-index", int.to_string(at))],
          ),
        ),
        ..acc
      ]
    })
    |> list.reverse
  let assert Ok(tape) =
    cassette.parse(cassette.encode(testing.script(exchanges)), 100_000)
  testing.exchanges(tape) |> should.equal(exchanges)
  let assert Ok(client) = testing.playback(tape, config.default())
  list.index_map(exchanges, fn(_, at) {
    let assert Error(mismatch) =
      http_gun.send(client, request.set_path(req(), "/mismatch"))
    error.reason(mismatch) |> should.equal(error.PlaybackMismatch(at))
    let assert Ok(reply) = http_gun.send(client, req())
    reply.response.status |> should.equal(200 + at)
    reply.response.body |> should.equal(bytes)
    reply.trailers |> should.equal([#("x-index", int.to_string(at))])
  })
  let assert Error(exhausted) = http_gun.send(client, req())
  error.reason(exhausted) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}
