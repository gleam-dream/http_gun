import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/option.{Some}
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/request_options
import http_gun/testing

type AppError {
  Startup(error.Failure)
  Rejected
}

pub fn request_ceiling_is_immutable_policy_not_liveness_test() {
  let settings = config.Config(..local_config(), deadline_ms: 1234)
  let assert Ok(live) = http_gun.start(settings)
  let assert Ok(script) = testing.start(settings, [])
  http_gun.request_ceiling_ms(live) |> should.equal(1234)
  http_gun.request_ceiling_ms(script) |> should.equal(1234)
  let _ = http_gun.stop(live)
  let _ = http_gun.stop(script)
  http_gun.request_ceiling_ms(live) |> should.equal(1234)
  http_gun.request_ceiling_ms(script) |> should.equal(1234)
  let assert Ok(other) = http_gun.start(local_config())
  http_gun.request_ceiling_ms(other) |> should.equal(30_000)
  http_gun.request_ceiling_ms(live) |> should.equal(1234)
  let _ = http_gun.stop(other)
}

pub fn fallible_token_preserves_callback_errors_and_closes_success_test() {
  cancellation.try_with_token(Startup, fn(_) { Error(Rejected) })
  |> should.equal(Error(Rejected))
  let assert Ok(#(token, value)) =
    cancellation.try_with_token(Startup, fn(token) { Ok(#(token, 42)) })
  value |> should.equal(42)
  cancellation.cancel(token)
  cancellation.cancel(token)
  let assert Ok(client) = http_gun.start(local_config())
  http_gun.send_with_options(
    client,
    request.new() |> request.set_body(<<>>),
    request_options.Options(
      ..request_options.default(),
      cancellation: Some(token),
    ),
  )
  |> should.equal(Error(error.Failure(error.Cancelled, error.NotSubmitted)))
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

pub fn fallible_scope_success_cancels_all_grouped_unfinished_bodies_test() {
  let #(port, peer) = controlled()
  let #(other_port, other_peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(#(one, two)) =
    cancellation.try_with_token(Startup, fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let assert Ok(one) =
        http_gun.open_with_options(client, req(port), options)
      let assert Ok(two) =
        http_gun.open_with_options(client, req(other_port), options)
      Ok(#(one.body, two.body))
    })
  let cancelled = Error(error.Failure(error.Cancelled, error.MayHaveBeenSent))
  body.next(one, 1000) |> should.equal(cancelled)
  body.next(two, 1000) |> should.equal(cancelled)
  closed(peer) |> should.be_true
  closed(other_peer) |> should.be_true
  let _ = body.close(one)
  let _ = body.close(two)
  let _ = http_gun.stop(client)
}

pub fn fallible_scope_callback_failure_cancels_http_test() {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  cancellation.try_with_token(Startup, fn(token) {
    let options =
      request_options.Options(
        ..request_options.default(),
        cancellation: Some(token),
      )
    let assert Ok(_) = http_gun.open_with_options(client, req(port), options)
    Error(Rejected)
  })
  |> should.equal(Error(Rejected))
  closed(peer) |> should.be_true
  let _ = http_gun.stop(client)
}

type ScopeProbe {
  ScopeProbe
}

@external(erlang, "http_gun_scope_test_ffi", "raised")
fn raised(run: fn() -> a) -> Bool

@external(erlang, "erlang", "error")
fn raise(reason: ScopeProbe) -> Nil

pub fn fallible_scope_exception_propagates_after_cleanup_test() {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  raised(fn() {
    cancellation.try_with_token(Startup, fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let assert Ok(_) = http_gun.open_with_options(client, req(port), options)
      raise(ScopeProbe)
      Ok(Nil)
    })
  })
  |> should.be_true
  closed(peer) |> should.be_true
  let _ = http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  let defaults = config.default()
  config.Config(
    ..defaults,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
    ),
  )
}
