import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_h2_server", "start")
fn server() -> Int

fn settings() -> config.Config {
  local_config()
  |> config.with_protocol(config.RequireHttp2)
  |> config.with_trust(config.CustomCa("test/fixtures/ca.crt"))
  |> config.with_max_connections(1)
  |> config.with_max_connections_per_origin(1)
}

// Wait at most a second for the next event; a local wait that passes is a
// failure here because every exercised stream sends promptly.
fn next(stream: body.Body) -> Result(body.Event, error.Failure) {
  case body.next_within(stream, 1000) {
    Ok(Some(event)) -> Ok(event)
    Ok(None) -> panic as "no body event within a second"
    Error(failure) -> Error(failure)
  }
}

fn req(port: Int, path: String) -> request.Request(BitArray) {
  request.new()
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

pub fn negotiated_multiplexed_cancellation_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(slow) = http_gun.open(client, req(port, "/slow"))
  let assert Ok(fast) = http_gun.open(client, req(port, "/fast"))
  body.protocol(slow.body) |> should.equal(config.H2)
  response_header(slow.headers, "x-connection")
  |> should.equal(response_header(fast.headers, "x-connection"))
  body.close(slow.body)
  next(fast.body) |> should.equal(Ok(body.Chunk(<<0, 255, 128>>)))
  next(fast.body) |> should.equal(Ok(body.End([])))
  body.close(fast.body)
  let assert Ok(third) = http_gun.send(client, req(port, "/fast"))
  response_header(third.response.headers, "x-connection")
  |> should.equal(response_header(slow.headers, "x-connection"))
  http_gun.stop(client)
}

pub fn h2_configured_header_count_excludes_status_pseudo_header_test() {
  let port = server()
  let c = settings()
  let assert Ok(client) = http_gun.start(c |> config.with_max_header_count(112))
  let assert Ok(reply) = http_gun.send(client, req(port, "/many-headers"))
  reply.protocol |> should.equal(config.H2)
  list.length(reply.response.headers) |> should.equal(112)
  http_gun.stop(client)
  let assert Ok(smaller) =
    http_gun.start(c |> config.with_max_header_count(111))
  http_gun.send(smaller, req(port, "/many-headers")) |> should.be_error
  http_gun.stop(smaller)
}

fn response_header(
  headers: List(#(String, String)),
  key: String,
) -> Result(String, Nil) {
  case headers {
    [] -> Error(Nil)
    [#(name, value), ..rest] ->
      case name == key {
        True -> Ok(value)
        False -> response_header(rest, key)
      }
  }
}

@external(erlang, "http_gun_h2_server", "controlled")
fn controlled() -> Int

pub fn h2_window_credit_after_buffered_frames_test() {
  let port = controlled()
  let config = settings()
  let assert Ok(client) =
    http_gun.start(
      config |> config.with_request_timeout(config.Milliseconds(1000)),
    )
  let assert Ok(value) = http_gun.send(client, req(port, "/window-demand"))
  bit_array.byte_size(value.response.body) |> should.equal(16_387)
  http_gun.stop(client)
}

pub fn zero_peer_capacity_expires_without_submission_test() {
  let port = server()
  let c = settings()
  let assert Ok(client) =
    http_gun.start(c |> config.with_request_timeout(config.Milliseconds(300)))
  let assert Ok(_) = http_gun.send(client, req(port, "/capacity-zero"))
  let assert Error(failure) = http_gun.send(client, req(port, "/fast"))
  error.evidence(failure) |> should.equal(error.NotSent)
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  http_gun.stop(client)
}

pub fn untrusted_tls_fails_without_submission_test() {
  let port = server()
  let c = settings()
  let assert Ok(client) =
    http_gun.start(
      c
      |> config.with_trust(config.SystemTrust)
      |> config.with_request_timeout(config.Milliseconds(1000)),
    )
  let assert Error(failure) = http_gun.send(client, req(port, "/fast"))
  error.evidence(failure) |> should.equal(error.NotSent)
  error.reason(failure)
  |> should.equal(error.ConnectionFailed(error.CertificateRejected))
  http_gun.stop(client)
}

pub fn h2_reset_preserves_sibling_and_connection_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(slow) = http_gun.open(client, req(port, "/slow"))
  let assert Error(_) = http_gun.send(client, req(port, "/reset"))
  let assert Ok(fast) = http_gun.send(client, req(port, "/fast"))
  response_header(fast.response.headers, "x-connection")
  |> should.equal(response_header(slow.headers, "x-connection"))
  next(slow.body) |> should.equal(Ok(body.Chunk(<<"first":utf8>>)))
  body.close(slow.body)
  http_gun.stop(client)
}

pub fn goaway_drains_then_explicit_request_opens_fresh_connection_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(first) = http_gun.send(client, req(port, "/goaway"))
  first.response.body |> should.equal(<<"done":utf8>>)
  await_no_connections(client, 1000) |> should.be_true
  let assert Ok(fresh) = http_gun.send(client, req(port, "/fast"))
  {
    response_header(first.response.headers, "x-connection")
    == response_header(fresh.response.headers, "x-connection")
  }
  |> should.be_false
  http_gun.stop(client)
}

fn await_no_connections(client: http_gun.Client, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.connections == 0 {
        True -> True
        False -> await_no_connections(client, tries - 1)
      }
    }
  }
}

@external(erlang, "http_gun_tls_test_server", "start")
fn tls_h1() -> Int

pub fn verified_tls_h1_fallback_test() {
  let c = settings()
  let assert Ok(client) =
    http_gun.start(c |> config.with_protocol(config.PreferHttp2))
  let assert Ok(reply) = http_gun.send(client, req(tls_h1(), "/"))
  reply.protocol |> should.equal(config.H1)
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn require_h2_refuses_h1_fallback_test() {
  let assert Ok(client) = http_gun.start(settings())
  let assert Error(failure) = http_gun.send(client, req(tls_h1(), "/"))
  error.evidence(failure) |> should.equal(error.NotSent)
  http_gun.stop(client)
}

pub fn tls_hostname_is_verified_test() {
  let assert Ok(client) = http_gun.start(settings())
  let assert Error(failure) =
    http_gun.send(
      client,
      req(server(), "/fast") |> request.set_host("127.0.0.1"),
    )
  error.evidence(failure) |> should.equal(error.NotSent)
  http_gun.stop(client)
}

fn queued(client: http_gun.Client, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.queued_requests == 5 {
        True -> True
        False -> queued(client, tries - 1)
      }
    }
  }
}

pub fn queued_streams_resume_after_cancellation_on_same_h2_connection_test() {
  let c = settings()
  let assert Ok(client) =
    http_gun.start(c |> config.with_max_streams_per_connection(1))
  let port = server()
  let assert Ok(slow) = http_gun.open(client, req(port, "/slow"))
  let done = process.new_subject()
  list.each(list.repeat(Nil, 5), fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(done, http_gun.send(client, req(port, "/fast")))
      })
    Nil
  })
  queued(client, 1000) |> should.be_true
  body.close(slow.body)
  list.each(list.repeat(Nil, 5), fn(_) {
    let assert Ok(Ok(reply)) = process.receive(done, 1000)
    reply.response.body |> should.equal(<<0, 255, 128>>)
    response_header(reply.response.headers, "x-connection")
    |> should.equal(response_header(slow.headers, "x-connection"))
  })
  http_gun.stop(client)
}

// Finch/Gun shutdown scenario: accepted siblings can finish during draining.
pub fn goaway_allows_existing_sibling_to_finish_without_replay_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(slow) = http_gun.open(client, req(port, "/slow"))
  next(slow.body) |> should.equal(Ok(body.Chunk(<<"first":utf8>>)))
  let assert Ok(draining) = http_gun.send(client, req(port, "/goaway-active"))
  draining.response.body |> should.equal(<<"done":utf8>>)
  let assert Ok(rest) = body.collect(slow.body, 100)
  rest.bytes |> should.equal(<<"tail":utf8>>)
  body.close(slow.body)
  // Gun does not expose atomic GOAWAY admission; await observed shutdown.
  await_no_connections(client, 1000) |> should.be_true
  let assert Ok(fresh) = http_gun.send(client, req(port, "/fast"))
  {
    response_header(fresh.response.headers, "x-connection")
    != response_header(slow.headers, "x-connection")
  }
  |> should.be_true
  http_gun.stop(client)
}

pub fn cancellation_token_preserves_h2_sibling_and_connection_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(settings())
  cancellation.with_token(fn(token) {
    let assert Ok(slow) =
      http_gun.open(
        http_gun.with_cancellation(client, token),
        req(port, "/slow"),
      )
    next(slow.body) |> should.equal(Ok(body.Chunk(<<"first":utf8>>)))
    let assert Ok(fast) = http_gun.open(client, req(port, "/fast"))
    cancellation.cancel(token)
    let assert Error(failure) = body.next_within(slow.body, 1000)
    error.reason(failure) |> should.equal(error.Cancelled)
    error.evidence(failure) |> should.equal(error.MaybeSent)
    let assert Ok(bytes) = body.collect(fast.body, 100)
    bytes.bytes |> should.equal(<<0, 255, 128>>)
    response_header(fast.headers, "x-connection")
    |> should.equal(response_header(slow.headers, "x-connection"))
    body.close(slow.body)
    body.close(fast.body)
    let assert Ok(after) = http_gun.send(client, req(port, "/fast"))
    response_header(after.response.headers, "x-connection")
    |> should.equal(response_header(slow.headers, "x-connection"))
  })
  http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
