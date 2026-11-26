//// A caller never outlives its budget because of a hostile response header
//// or a dead body owner.

import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleeunit/should
import http_gun
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

@external(erlang, "http_gun_owner_fault_test_ffi", "monitored_by")
fn monitored_by(pid: process.Pid) -> List(process.Pid)

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

// Run `send` in its own process so a caller that never returns fails the
// test instead of hanging it.
fn send_elsewhere(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> #(process.Pid, process.Subject(Result(http_gun.Buffered, error.Failure))) {
  let outcome = process.new_subject()
  let caller =
    process.spawn_unlinked(fn() {
      process.send(outcome, http_gun.send(client, req))
    })
  #(caller, outcome)
}

pub fn non_utf8_response_header_bytes_cannot_strand_the_caller_test() {
  [
    <<
      "HTTP/1.1 200 OK\r\nConnection: clo":utf8, 255,
      "se\r\nContent-Length: 3\r\n\r\nabc":utf8,
    >>,
    <<
      "HTTP/1.1 200 OK\r\nX-A: ":utf8,
      255,
      "\r\nContent-Length: 0\r\n\r\n":utf8,
    >>,
    <<
      "HTTP/1.1 200 OK\r\nX-":utf8,
      255,
      ": a\r\nContent-Length: 0\r\n\r\n":utf8,
    >>,
    <<
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n0\r\nx-t: ":utf8,
      255, "\r\n\r\n":utf8,
    >>,
  ]
  |> list.each(fn(bytes) {
    let assert Ok(client) =
      http_gun.start(config.allow_loopback(config.default()))
    let #(_, outcome) = send_elsewhere(client, req(serve(bytes)))
    // A response or a typed failure both answer the caller; silence is the
    // defect.
    let assert Ok(_) = process.receive(outcome, 2000)
    http_gun.stop(client)
  })
}

pub fn body_owner_death_before_the_head_is_a_typed_failure_test() {
  let #(port, server) = gated()
  let assert Ok(client) =
    http_gun.start(config.allow_loopback(config.default()))
  let #(caller, outcome) = send_elsewhere(client, req(port))
  // The server holds the request without answering, so the caller is waiting
  // for the head and only its body owner monitors it.
  await_request(server)
  // The pool answers only after the body owner's start has returned and the
  // pool has dropped its own monitor of the caller.
  let _ = http_gun.stats(client)
  let assert [owner] = monitored_by(caller)
  process.kill(owner)
  let assert Ok(Error(failure)) = process.receive(outcome, 2000)
  error.reason(failure)
  |> should.equal(error.RequestFailed(error.UnknownTransport))
  error.evidence(failure) |> should.equal(error.MaybeSent)
  http_gun.stop(client)
}
