import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/error

@external(erlang, "http_gun_reuse_test_server", "close_peer")
fn close_peer(server: process.Pid) -> Nil

@external(erlang, "http_gun_reuse_test_server", "start")
fn server(tls: Bool, close_header: Bool) -> #(Int, process.Pid)

@external(erlang, "http_gun_reuse_test_server", "stop")
fn stop(server: process.Pid) -> Nil

fn settings() -> config.Config {
  config.default()
  |> config.with_trust(config.CustomCa("test/fixtures/ca.crt"))
  |> config.allow_loopback
  |> config.with_max_connections(1)
  |> config.with_max_connections_per_origin(1)
}

pub fn main() {
  request_close_is_not_reused_test()
  closed_idle_tls_connection_is_not_submitted_to_test()
  response_close_is_not_reused_test()
  readiness_wait_uses_the_original_deadline_test()
}

pub fn closed_idle_tls_connection_is_not_submitted_to_test() {
  let #(port, peer) = server(True, False)
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(req) = request.to("https://localhost:" <> int.to_string(port))
  let req = request.set_body(req, <<>>)
  let assert Ok(_) = http_gun.send(client, req)
  close_peer(peer)
  // Server close is acknowledged. Exercise the measured 200ms Gun TLS-alert
  // wait specifically; waiting for gun_down here would hide the regression.
  process.sleep(100)
  let second = http_gun.send(client, req)
  http_gun.stop(client)
  stop(peer)
  let assert Ok(second) = second
  response.get_header(second.response, "x-connection") |> should.equal(Ok("2"))
  response.get_header(second.response, "x-sequence") |> should.equal(Ok("1"))
}

pub fn request_close_is_not_reused_test() {
  closing_requests(False)
}

pub fn response_close_is_not_reused_test() {
  closing_requests(True)
}

fn closing_requests(response_close: Bool) -> Nil {
  let #(port, peer) = server(True, response_close)
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(req) = request.to("https://localhost:" <> int.to_string(port))
  let req = request.set_body(req, <<>>)
  let req = case response_close {
    True -> req
    False -> request.set_header(req, "connection", "Keep-Alive, Close")
  }
  list.each([1, 2, 3, 4, 5, 6, 7, 8], fn(index) {
    let assert Ok(reply) = http_gun.send(client, req)
    response.get_header(reply.response, "x-connection")
    |> should.equal(Ok(int.to_string(index)))
    response.get_header(reply.response, "x-sequence") |> should.equal(Ok("1"))
  })
  http_gun.stop(client)
  stop(peer)
}

pub fn readiness_wait_uses_the_original_deadline_test() {
  let #(port, peer) = server(True, False)
  let assert Ok(client) = http_gun.start(settings())
  let assert Ok(req) = request.to("https://localhost:" <> int.to_string(port))
  let req = request.set_body(req, <<>>)
  let assert Ok(_) = http_gun.send(client, req)
  close_peer(peer)
  process.sleep(100)
  let until = deadline.after(10)
  let outcome = http_gun.send(client |> http_gun.with_deadline(until), req)
  http_gun.stop(client)
  stop(peer)
  outcome
  |> should.equal(Error(error.new(error.DeadlineExceeded, error.NotSent)))
}
