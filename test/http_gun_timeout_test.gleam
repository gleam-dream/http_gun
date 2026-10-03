//// Named timeouts: connect including DNS, and the view's request timeout.

import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "http_gun_ffi", "now")
fn now() -> Int

fn named(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://slow.test:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn slow_resolver(delay: Int) -> config.Resolver {
  fn(_host, _remaining) {
    process.sleep(delay)
    Ok([destination.Ipv4(127, 0, 0, 1)])
  }
}

pub fn dns_counts_against_the_connect_timeout_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.allow_loopback
      |> config.with_resolver(slow_resolver(1000))
      |> config.with_connect_timeout(150),
    )
  let started = now()
  let assert Error(failure) = http_gun.send(client, named(port))
  let elapsed = now() - started
  error.reason(failure) |> should.equal(error.ConnectTimeout)
  error.evidence(failure) |> should.equal(error.NotSent)
  error.kind(failure) |> should.equal(error.TimedOut)
  error.is_retryable(failure, idempotent: False) |> should.be_true
  { elapsed >= 140 && elapsed < 900 } |> should.be_true
  http_gun.stop(client)
}

pub fn resolution_within_the_connect_timeout_succeeds_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.allow_loopback
      |> config.with_resolver(slow_resolver(50))
      |> config.with_connect_timeout(2000),
    )
  let assert Ok(buffered) = http_gun.send(client, named(port))
  buffered.response.body |> should.equal(<<"abc">>)
  http_gun.stop(client)
}

pub fn a_shorter_view_timeout_bounds_dns_too_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.allow_loopback
      |> config.with_resolver(slow_resolver(1000)),
    )
  let assert Error(failure) =
    client
    |> http_gun.with_timeout(config.Milliseconds(100))
    |> http_gun.send(named(port))
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  error.evidence(failure) |> should.equal(error.NotSent)
  http_gun.stop(client)
}

pub fn infinite_client_timeout_is_explicit_and_valid_test() {
  config.default()
  |> config.with_request_timeout(config.Infinity)
  |> config.with_idle_timeout(config.Infinity)
  |> config.validate
  |> should.be_ok
  config.default()
  |> config.with_idle_timeout(config.Milliseconds(0))
  |> config.validate
  |> should.equal(Error(config.OutOfRange(config.IdleTimeout, 0)))
  config.default()
  |> config.with_pool_timeout(-1)
  |> http_gun.start
  |> should.equal(
    Error(http_gun.InvalidConfig(config.OutOfRange(config.PoolTimeout, -1))),
  )
}
