import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/error

type AppError {
  Rejected
}

pub fn token_scope_preserves_callback_value_and_cancels_on_return_test() {
  cancellation.with_token(fn(_) { Error(Rejected) })
  |> should.equal(Error(Rejected))
  let #(token, value) = cancellation.with_token(fn(token) { #(token, 42) })
  value |> should.equal(42)
  // Returning from the scope cancels the token; cancelling again is a no-op.
  cancellation.is_cancelled(token) |> should.be_true
  cancellation.cancel(token)
  cancellation.cancel(token)
  let assert Ok(client) = http_gun.start(local_config())
  http_gun.send(
    client |> http_gun.with_cancellation(token),
    request.new() |> request.set_body(<<>>),
  )
  |> should.equal(Error(error.new(error.Cancelled, error.NotSent)))
  http_gun.stop(client)
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

pub fn token_scope_return_cancels_all_grouped_unfinished_bodies_test() {
  let #(port, peer) = controlled()
  let #(other_port, other_peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let #(one, two) =
    cancellation.with_token(fn(token) {
      let view = client |> http_gun.with_cancellation(token)
      let assert Ok(one) = http_gun.open(view, req(port))
      let assert Ok(two) = http_gun.open(view, req(other_port))
      #(one.body, two.body)
    })
  // The head had arrived, so the failure carries the response status.
  let cancelled =
    Error(error.new(error.Cancelled, error.MaybeSent) |> error.with_status(200))
  body.next_within(one, duration.milliseconds(1000)) |> should.equal(cancelled)
  body.next_within(two, duration.milliseconds(1000)) |> should.equal(cancelled)
  closed(peer) |> should.be_true
  closed(other_peer) |> should.be_true
  body.close(one)
  body.close(two)
  http_gun.stop(client)
}

pub fn token_scope_callback_error_cancels_http_test() {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  cancellation.with_token(fn(token) {
    let assert Ok(_) =
      http_gun.open(client |> http_gun.with_cancellation(token), req(port))
    Error(Rejected)
  })
  |> should.equal(Error(Rejected))
  closed(peer) |> should.be_true
  http_gun.stop(client)
}

type ScopeProbe {
  ScopeProbe
}

@external(erlang, "http_gun_scope_test_ffi", "raised")
fn raised(run: fn() -> a) -> Bool

@external(erlang, "erlang", "error")
fn raise(reason: ScopeProbe) -> Nil

pub fn token_scope_exception_propagates_after_cleanup_test() {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  raised(fn() {
    cancellation.with_token(fn(token) {
      let assert Ok(_) =
        http_gun.open(client |> http_gun.with_cancellation(token), req(port))
      raise(ScopeProbe)
      Ok(Nil)
    })
  })
  |> should.be_true
  closed(peer) |> should.be_true
  http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
