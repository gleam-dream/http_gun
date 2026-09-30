import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import gleeunit
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/error

pub fn main() {
  gleeunit.main()
}

@external(erlang, "http_gun_test_server", "start")
fn server() -> Int

pub fn real_binary_request_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  let assert Ok(received) = http_gun.send(client, request.set_body(req, <<>>))
  received.response.status |> should.equal(201)
  received.response.body |> should.equal(<<0, 255, 128>>)
  let _ = http_gun.stop(client)
  bit_array.byte_size(received.response.body) |> should.equal(3)
}

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(value) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(value, <<>>)
}

pub fn final_headers_duplicates_and_trailers_test() {
  let port =
    serve(<<
      "HTTP/1.1 103 Early Hints\r\nLink: </x>\r\n\r\nHTTP/1.1 429 Slow Down\r\nTransfer-Encoding: chunked\r\nX-Repeat: a\r\nX-Repeat: b\r\n\r\n3\r\n":utf8,
      0,
      255,
      128,
      "\r\n0\r\nX-End: yes\r\n\r\n":utf8,
    >>)
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(value) = http_gun.send(client, req(port))
  value.response.status |> should.equal(429)
  value.response.body |> should.equal(<<0, 255, 128>>)
  value.trailers |> should.equal([#("x-end", "yes")])
  value.response.headers
  |> should.equal([
    #("transfer-encoding", "chunked"),
    #("x-repeat", "a"),
    #("x-repeat", "b"),
  ])
  let _ = http_gun.stop(client)
}

pub fn arbitrary_methods_and_empty_status_test() {
  let assert Ok(client) = http_gun.start(config.default())
  list.each(
    [
      http.Get,
      http.Post,
      http.Put,
      http.Patch,
      http.Delete,
      http.Options,
      http.Head,
      http.Trace,
    ],
    fn(method) {
      let port =
        serve(bit_array.from_string(
          "HTTP/1.1 204 No Content\r\nX-Ok: yes\r\n\r\n",
        ))
      let assert Ok(value) =
        http_gun.send(client, request.set_method(req(port), method))
      value.response.status |> should.equal(204)
      value.response.body |> should.equal(<<>>)
    },
  )
  let _ = http_gun.stop(client)
}

pub fn invalid_config_test() {
  let settings = config.default()
  http_gun.start(config.Config(..settings, deadline_ms: 0)) |> should.be_error
}

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

pub fn batch_preserves_input_order_and_binary_bodies_test() {
  let port = persistent()
  let assert Ok(client) = http_gun.start(config.default())
  let requests =
    list.map(
      list.index_map(list.repeat(Nil, 30), fn(_, index) { index + 1 }),
      fn(index) {
        req(port)
        |> request.set_method(http.Post)
        |> request.set_body(<<index>>)
      },
    )
  let assert Ok(results) = http_gun.batch(client, requests, 3)
  list.map(results, fn(result) {
    let assert Ok(value) = result
    value.response.body
  })
  |> should.equal(
    list.map(
      list.index_map(list.repeat(Nil, 30), fn(_, index) { index + 1 }),
      fn(index) { <<index>> },
    ),
  )
  let _ = http_gun.stop(client)
}

pub fn h1_reuses_idle_connection_test() {
  let port = persistent()
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(first) = http_gun.send(client, req(port))
  let assert Ok(second) = http_gun.send(client, req(port))
  response.get_header(first.response, "x-connection")
  |> should.equal(response.get_header(second.response, "x-connection"))
  response.get_header(first.response, "x-connection") |> should.be_ok
  let assert Ok(stats) = http_gun.snapshot(client)
  stats.connections |> should.equal(1)
  let _ = http_gun.stop(client)
}

pub fn host_only_url_uses_root_target_test() {
  let port = persistent()
  let assert Ok(base) = request.to("http://localhost:" <> int.to_string(port))
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(value) = http_gun.send(client, request.set_body(base, <<>>))
  value.response.body |> should.equal(<<"abc":utf8>>)
  let _ = http_gun.stop(client)
}

pub fn invalid_method_and_query_fail_before_submission_test() {
  let assert Ok(client) = http_gun.start(config.default())
  let invalid = req(1) |> request.set_method(http.Other("GET\r\nX: value"))
  let assert Error(failure) = http_gun.send(client, invalid)
  failure.reason
  |> should.equal(error.InvalidRequest("invalid origin, target or header"))
  failure.evidence |> should.equal(error.NotSubmitted)
  let _ = http_gun.stop(client)
}

pub fn informational_headers_respect_admitted_head_limit_test() {
  let port =
    serve(<<
      "HTTP/1.1 103 Early Hints\r\nX-Hint: 012345678901234567890123456789\r\n\r\nHTTP/1.1 204 No Content\r\n\r\n":utf8,
    >>)
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, limits: config.Limits(..c.limits, head_bytes: 16)),
    )
  let assert Error(failure) = http_gun.send(client, req(port))
  failure.reason |> should.equal(error.LimitExceeded("headers", 16))
  let _ = http_gun.stop(client)
}

pub fn batch_failure_preserves_unrelated_results_test() {
  let port = persistent()
  let failure_port = serve(<<"bad HTTP\r\n":utf8>>)
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok([Ok(a), Error(failure), Ok(b)]) =
    http_gun.batch(client, [req(port), req(failure_port), req(port)], 2)
  a.response.body |> should.equal(<<"abc":utf8>>)
  b.response.body |> should.equal(<<"abc":utf8>>)
  failure.evidence |> should.equal(error.MayHaveBeenSent)
  let _ = http_gun.stop(client)
}

pub fn partial_byte_request_is_rejected_before_submission_test() {
  let assert Ok(client) = http_gun.start(config.default())
  let assert Error(failure) =
    http_gun.send(client, req(1) |> request.set_body(<<1:size(1)>>))
  failure.evidence |> should.equal(error.NotSubmitted)
  failure.reason
  |> should.equal(error.InvalidRequest("body must contain whole bytes"))
  let _ = http_gun.stop(client)
}

pub fn configured_header_count_above_gun_default_test() {
  let bytes =
    bit_array.from_string(
      "HTTP/1.1 204 No Content\r\n"
      <> string.repeat("x-many: a\r\n", 110)
      <> "\r\n",
    )
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, limits: config.Limits(..c.limits, header_count: 110)),
    )
  let assert Ok(reply) = http_gun.send(client, req(serve(bytes)))
  reply.response.status |> should.equal(204)
  list.length(reply.response.headers) |> should.equal(110)
  let _ = http_gun.stop(client)
  let assert Ok(default_client) = http_gun.start(c)
  http_gun.send(default_client, req(serve(bytes))) |> should.be_error
  let _ = http_gun.stop(default_client)
}
