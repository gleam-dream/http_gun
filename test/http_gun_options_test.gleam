import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/redaction
import http_gun/testing

pub fn expired_deadline_refuses_before_submission_test() {
  let assert Ok(client) = http_gun.start(local_config())
  let budget = deadline.after(duration.milliseconds(0))
  let req =
    request.new() |> request.set_host("localhost") |> request.set_body(<<>>)
  let assert Error(failure) =
    http_gun.send(client |> http_gun.with_deadline(budget), req)
  failure |> should.equal(error.new(error.DeadlineExceeded, error.NotSent))
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(0)
  http_gun.stop(client)
}

pub fn cancelled_token_refuses_fresh_work_test() {
  let assert Ok(client) = http_gun.start(local_config())
  cancellation.with_token(fn(token) {
    cancellation.cancel(token)
    cancellation.cancel(token)
    cancellation.is_cancelled(token) |> should.be_true
    let req =
      request.new() |> request.set_host("localhost") |> request.set_body(<<>>)
    http_gun.send(client |> http_gun.with_cancellation(token), req)
    |> should.equal(Error(error.new(error.Cancelled, error.NotSent)))
  })
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(0)
  http_gun.stop(client)
}

fn oversized_script() -> #(request.Request(BitArray), testing.Exchange) {
  let req = request.new() |> request.set_body(<<>>)
  let reply =
    response.new(200)
    |> response.set_header("x-receipt", "accepted")
    |> response.set_body([<<"abc":utf8>>, <<"def":utf8>>])
  #(req, testing.exchange(req, testing.Respond(reply, testing.Finished([]))))
}

pub fn truncate_overflow_keeps_status_and_headers_test() {
  let #(req, exchange) = oversized_script()
  let assert Ok(client) = playback([exchange], config.default())
  let assert Ok(buffered) =
    http_gun.send(client |> http_gun.with_body_limit(4, http_gun.Truncate), req)
  buffered.response.status |> should.equal(200)
  response.get_header(buffered.response, "x-receipt")
  |> should.equal(Ok("accepted"))
  buffered.response.body |> should.equal(<<"abcd":utf8>>)
  buffered.truncated |> should.be_true
  buffered.trailers |> should.equal([])
  http_gun.stop(client)
}

// A 429 whose body exceeds the limit keeps the headers a caller decides on,
// after the client's redaction.
pub fn fail_overflow_keeps_status_and_redacted_headers_test() {
  let req = request.new() |> request.set_body(<<>>)
  let reply =
    response.Response(
      429,
      [
        #("retry-after", "30"),
        #("set-cookie", "session=secret"),
        #("x-signature", "secret"),
        #("link", "<a>"),
        #("link", "<b>"),
      ],
      [<<"abc":utf8>>, <<"def":utf8>>],
    )
  let exchange =
    testing.exchange(req, testing.Respond(reply, testing.Finished([])))
  let settings =
    config.default()
    |> config.with_redaction(
      redaction.default() |> redaction.with_headers(["X-Signature"]),
    )
  let assert Ok(client) = playback([exchange, exchange], settings)
  let assert Error(failure) =
    http_gun.send(client |> http_gun.with_body_limit(4, http_gun.Fail), req)
  error.reason(failure)
  |> should.equal(error.LimitExceeded(error.ResponseBodyBytes, 4, 6))
  error.status(failure) |> should.equal(Some(429))
  error.headers(failure)
  |> should.equal([
    #("retry-after", "30"),
    #("link", "<a>"),
    #("link", "<b>"),
  ])
  list.key_find(error.headers(failure), "retry-after")
  |> should.equal(Ok("30"))
  // The stored record keeps them too.
  json.to_string(error.to_json(failure))
  |> json.parse(error.decoder())
  |> should.equal(Ok(failure))
  // A batch failure keeps them the same way.
  let assert Ok([Error(batched)]) =
    http_gun.batch(
      client |> http_gun.with_body_limit(4, http_gun.Fail),
      [req],
      1,
    )
  error.headers(batched) |> should.equal(error.headers(failure))
  http_gun.stop(client)
}

pub fn per_request_collect_limit_replaces_client_limit_test() {
  let #(req, exchange) = oversized_script()
  let assert Ok(client) = playback([exchange, exchange], config.default())
  // An oversized collected body fails with the response status.
  http_gun.send(client |> http_gun.with_body_limit(5, http_gun.Fail), req)
  |> should.equal(Error(
    error.new(
      error.LimitExceeded(error.ResponseBodyBytes, 5, 6),
      error.MaybeSent,
    )
    |> error.with_status(200)
    |> error.with_headers([#("x-receipt", "accepted")]),
  ))
  let wide = fn(client) {
    client |> http_gun.with_body_limit(6, http_gun.Truncate)
  }
  let assert Ok(buffered) = http_gun.send(wide(client), req)
  buffered.response.body |> should.equal(<<"abcdef":utf8>>)
  buffered.truncated |> should.be_false
  http_gun.stop(client)
  let settings = config.default() |> config.with_max_response_body_bytes(2)
  let assert Ok(client) = playback([exchange], settings)
  let assert Ok(buffered) = http_gun.send(wide(client), req)
  buffered.response.body |> should.equal(<<"abcdef":utf8>>)
  http_gun.stop(client)
}

pub fn negative_collect_limit_is_rejected_before_submission_test() {
  let #(req, exchange) = oversized_script()
  let assert Ok(client) = playback([exchange], config.default())
  http_gun.send(client |> http_gun.with_body_limit(-1, http_gun.Truncate), req)
  |> should.equal(
    Error(error.new(error.InvalidRequest(error.InvalidBodyLimit), error.NotSent)),
  )
  let assert Ok(buffered) = http_gun.send(client, req)
  buffered.response.body |> should.equal(<<"abcdef":utf8>>)
  buffered.truncated |> should.be_false
  http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

pub fn token_cancels_before_headers_without_killing_caller_test() {
  let #(port, server) = gated()
  let assert Ok(client) = http_gun.start(local_config())
  let result = process.new_subject()
  let alive = process.new_subject()
  cancellation.with_token(fn(token) {
    let view = client |> http_gun.with_cancellation(token)
    let _ =
      process.spawn_unlinked(fn() {
        process.send(result, http_gun.open(view, req(port)))
        process.send(alive, Nil)
      })
    await_request(server)
    cancellation.cancel(token)
    let assert Ok(Error(failure)) = process.receive(result, 1000)
    failure |> should.equal(error.new(error.Cancelled, error.MaybeSent))
    process.receive(alive, 1000) |> should.equal(Ok(Nil))
    closed(server) |> should.be_true
  })
  http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

pub fn queued_cancellation_removes_waiter_without_submission_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_open_bodies(1))
  let assert Ok(held) = http_gun.open(client, req(port))
  let result = process.new_subject()
  cancellation.with_token(fn(token) {
    let view = client |> http_gun.with_cancellation(token)
    let _ =
      process.spawn_unlinked(fn() {
        process.send(result, http_gun.send(view, req(port)))
      })
    wait_for_queue(client, 1, 1000) |> should.be_true
    cancellation.cancel(token)
    let assert Ok(Error(failure)) = process.receive(result, 1000)
    failure |> should.equal(error.new(error.Cancelled, error.NotSent))
    wait_for_queue(client, 0, 1000) |> should.be_true
  })
  body.close(held.body)
  closed(server) |> should.be_true
  http_gun.stop(client)
}

fn wait_for_queue(client: http_gun.Client, size: Int, tries: Int) -> Bool {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.queued_requests == size, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> wait_for_queue(client, size, tries - 1)
  }
}

pub fn cancellation_during_tls_setup_releases_connection_reservation_test() {
  let #(port, server) = gated()
  let assert Ok(client) =
    http_gun.start(
      local_config() |> config.with_connect_timeout(duration.milliseconds(500)),
    )
  let result = process.new_subject()
  cancellation.with_token(fn(token) {
    let view = client |> http_gun.with_cancellation(token)
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          result,
          http_gun.send(view, req(port) |> request.set_scheme(http.Https)),
        )
      })
    await_request(server)
    cancellation.cancel(token)
    let assert Ok(Error(failure)) = process.receive(result, 1000)
    failure |> should.equal(error.new(error.Cancelled, error.NotSent))
    let assert Ok(stats) = http_gun.stats(client)
    stats.connections |> should.equal(0)
  })
  http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "send_control")
fn send_control(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_ffi", "now")
fn now() -> Int

pub fn supplied_deadline_covers_body_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let budget = deadline.after(duration.milliseconds(100))
  let assert Ok(response) =
    http_gun.open(client |> http_gun.with_deadline(budget), req(port))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Error(
    error.new(error.DeadlineExceeded, error.MaybeSent)
    |> error.with_status(200),
  ))
  duration.to_milliseconds(deadline.remaining(budget)) |> should.equal(0)
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

// Regression: a view deadline replaces the client's request timeout instead
// of taking the earlier of the two, so a per-call budget may exceed the
// client's default.
pub fn view_deadline_longer_than_client_request_timeout_succeeds_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(100))),
    )
  let assert Ok(response) =
    http_gun.open(
      client
        |> http_gun.with_deadline(deadline.after(duration.milliseconds(5000))),
      req(port),
    )
  // Outlive the client's 100 ms request timeout before the body arrives.
  process.sleep(300)
  send_control(server, <<"3\r\nabc\r\n0\r\n\r\n":utf8>>)
  body.collect(response.body, 100)
  |> should.equal(Ok(body.Collected(<<"abc":utf8>>, [])))
  body.close(response.body)
  // The same wait through the client itself still meets its own timeout.
  let #(port, server) = controlled()
  let assert Ok(response) = http_gun.open(client, req(port))
  process.sleep(300)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Error(
    error.new(error.DeadlineExceeded, error.MaybeSent)
    |> error.with_status(200),
  ))
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

pub fn infinite_view_timeout_outlives_request_timeout_but_not_idle_timeout_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(200)))
      |> config.with_idle_timeout(config.After(duration.milliseconds(300))),
    )
  let stream = client |> http_gun.with_timeout(config.Infinity)
  // A body that keeps flowing for longer than the request timeout.
  let #(port, server) = controlled()
  let before = now()
  let assert Ok(response) = http_gun.open(stream, req(port))
  list.each(list.repeat(Nil, 6), fn(_) {
    process.sleep(100)
    send_control(server, <<"1\r\na\r\n":utf8>>)
    body.next(response.body) |> should.equal(Ok(body.Chunk(<<"a":utf8>>)))
  })
  send_control(server, <<"0\r\n\r\n":utf8>>)
  body.next(response.body) |> should.equal(Ok(body.End([])))
  { now() - before >= 600 } |> should.be_true
  body.close(response.body)
  // A stalled stream still fails with the idle timeout.
  let #(port, server) = controlled()
  let assert Ok(response) = http_gun.open(stream, req(port))
  let before = now()
  body.next(response.body)
  |> should.equal(Error(
    error.new(error.IdleTimeout, error.MaybeSent) |> error.with_status(200),
  ))
  let waited = now() - before
  { waited >= 250 && waited < 2000 } |> should.be_true
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

pub fn scope_exit_cancels_stream_and_returned_token_stays_cancelled_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let #(response, token) =
    cancellation.with_token(fn(token) {
      let assert Ok(response) =
        http_gun.open(client |> http_gun.with_cancellation(token), req(port))
      #(response, token)
    })
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Error(
    error.new(error.Cancelled, error.MaybeSent) |> error.with_status(200),
  ))
  closed(server) |> should.be_true
  body.close(response.body)
  cancellation.is_cancelled(token) |> should.be_true
  http_gun.send(client |> http_gun.with_cancellation(token), req(port))
  |> should.equal(Error(error.new(error.Cancelled, error.NotSent)))
  http_gun.stop(client)
}

pub fn cancellation_creator_death_unblocks_independent_consumer_test() {
  let #(port, server) = gated()
  let assert Ok(client) = http_gun.start(local_config())
  let ready = process.new_subject()
  let result = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      cancellation.with_token(fn(token) {
        process.send(ready, token)
        process.sleep_forever()
      })
    })
  let assert Ok(token) = process.receive(ready, 1000)
  let view = client |> http_gun.with_cancellation(token)
  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, http_gun.send(view, req(port)))
    })
  await_request(server)
  process.kill(creator)
  let assert Ok(Error(failure)) = process.receive(result, 1000)
  failure |> should.equal(error.new(error.Cancelled, error.MaybeSent))
  closed(server) |> should.be_true
  http_gun.stop(client)
}

pub fn completed_http_survives_later_cancellation_test() {
  let req = req(80)
  let exchange =
    testing.exchange(
      req,
      testing.Respond(
        response.new(204) |> response.set_body([]),
        testing.Finished([#("x-end", "yes")]),
      ),
    )
  let assert Ok(client) = playback([exchange], local_config())
  cancellation.with_token(fn(token) {
    let assert Ok(response) =
      http_gun.open(client |> http_gun.with_cancellation(token), req)
    body.next_within(response.body, duration.milliseconds(1000))
    |> should.equal(Ok(Some(body.End([#("x-end", "yes")]))))
    cancellation.cancel(token)
    body.next_within(response.body, duration.milliseconds(1000))
    |> should.equal(Ok(Some(body.End([#("x-end", "yes")]))))
    body.close(response.body)
  })
  http_gun.stop(client)
}

pub fn last_queued_cancellation_releases_shared_connecting_socket_test() {
  let #(port, server) = gated()
  let assert Ok(client) =
    http_gun.start(
      local_config() |> config.with_connect_timeout(duration.milliseconds(5000)),
    )
  let results = process.new_subject()
  let request = req(port) |> request.set_scheme(http.Https)
  cancellation.with_token(fn(first) {
    cancellation.with_token(fn(second) {
      let first_view = client |> http_gun.with_cancellation(first)
      let second_view = client |> http_gun.with_cancellation(second)
      let _ =
        process.spawn_unlinked(fn() {
          process.send(results, http_gun.send(first_view, request))
        })
      await_request(server)
      let _ =
        process.spawn_unlinked(fn() {
          process.send(results, http_gun.send(second_view, request))
        })
      wait_for_queue(client, 1, 1000) |> should.be_true
      cancellation.cancel(first)
      let assert Ok(Error(failure)) = process.receive(results, 1000)
      failure |> should.equal(error.new(error.Cancelled, error.NotSent))
      let assert Ok(stats) = http_gun.stats(client)
      stats.connections |> should.equal(1)
      cancellation.cancel(second)
      let assert Ok(Error(failure)) = process.receive(results, 1000)
      failure |> should.equal(error.new(error.Cancelled, error.NotSent))
      let assert Ok(stats) = http_gun.stats(client)
      stats.connections |> should.equal(0)
    })
  })
  http_gun.stop(client)
}

fn playback(
  exchanges: List(testing.Exchange),
  settings: config.Config,
) -> Result(http_gun.Client, http_gun.StartError) {
  testing.playback(testing.script(exchanges), settings)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
