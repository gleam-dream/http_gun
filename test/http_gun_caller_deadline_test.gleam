//// A caller's own process ends its wait at the request deadline, even when
//// the pool is alive but handles no messages.

import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/option
import gleam/otp/static_supervisor
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_caller_deadline_test_ffi", "suspend")
fn suspend(pid: process.Pid) -> Nil

@external(erlang, "http_gun_caller_deadline_test_ffi", "resume")
fn resume(pid: process.Pid) -> Nil

@external(erlang, "http_gun_caller_deadline_test_ffi", "queued")
fn queued(pid: process.Pid) -> Int

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_owner_fault_test_ffi", "monitored_by")
fn monitored_by(pid: process.Pid) -> List(process.Pid)

fn blocked_client() -> #(http_gun.Client, process.Pid) {
  let name = process.new_name("http_gun_caller_deadline")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(
      config.allow_loopback(config.default()),
      name,
    ))
    |> static_supervisor.start
  let assert Ok(pool) = process.named(name)
  #(http_gun.named(name), pool)
}

pub fn blocked_pool_cannot_hold_a_caller_past_its_deadline_test() {
  let port = serve(<<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n":utf8>>)
  let assert Ok(req) = request.to("http://localhost:" <> int.to_string(port))
  let req = request.set_body(req, <<>>)
  let #(client, pool) = blocked_client()
  suspend(pool)
  // A question that submits nothing is bounded the same way.
  http_gun.stats(http_gun.with_timeout(client, duration.milliseconds(100)))
  |> should.equal(Error(error.new(error.DeadlineExceeded, error.NotSent)))
  let outcome = process.new_subject()
  let caller =
    process.spawn(fn() {
      let done = process.new_subject()
      let client = http_gun.with_timeout(client, duration.milliseconds(200))
      process.send(outcome, #(done, http_gun.send(client, req)))
      // Stay alive so the test can look for a late reply in this mailbox.
      process.receive_forever(done)
    })
  let assert Ok(#(done, Error(failure))) = process.receive(outcome, 2000)
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  error.evidence(failure) |> should.equal(error.MaybeSent)
  // The pool now handles the abandoned request; its answer must not reach
  // the caller. Two round trips let any reply the pool owes be sent first.
  resume(pool)
  let assert Ok(_) = http_gun.stats(client)
  let assert Ok(_) = http_gun.stats(client)
  queued(caller) |> should.equal(0)
  process.send(done, Nil)
}

pub fn blocked_body_owner_cannot_hold_a_reader_past_its_deadline_test() {
  let #(port, _server) = controlled()
  let assert Ok(req) = request.to("http://localhost:" <> int.to_string(port))
  let req = request.set_body(req, <<>>)
  let assert Ok(client) =
    http_gun.start(config.allow_loopback(config.default()))
  let outcome = process.new_subject()
  let opened = process.new_subject()
  let caller =
    process.spawn(fn() {
      let go = process.new_subject()
      let client = http_gun.with_timeout(client, duration.milliseconds(300))
      let assert Ok(response) = http_gun.open(client, req)
      process.send(opened, go)
      process.receive_forever(go)
      process.send(outcome, body.next(response.body))
      process.receive_forever(go)
    })
  let assert Ok(go) = process.receive(opened, 2000)
  // Only the body owner monitors the caller once the head has arrived.
  let assert [owner] = monitored_by(caller)
  suspend(owner)
  process.send(go, Nil)
  let assert Ok(Error(failure)) = process.receive(outcome, 2000)
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  error.evidence(failure) |> should.equal(error.MaybeSent)
  error.status(failure) |> should.equal(option.Some(200))
  resume(owner)
  // The owner now answers the abandoned read; the answer must not arrive.
  let _ = http_gun.stats(client)
  process.sleep(50)
  queued(caller) |> should.equal(0)
  process.send(go, Nil)
  http_gun.stop(client)
}

pub fn zero_timeout_fails_before_anything_is_sent_test() {
  let assert Ok(client) =
    http_gun.start(config.allow_loopback(config.default()))
  let assert Ok(req) = request.to("http://localhost:1/")
  let assert Error(failure) =
    http_gun.send(
      http_gun.with_timeout(client, duration.milliseconds(0)),
      request.set_body(req, <<>>),
    )
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  error.evidence(failure) |> should.equal(error.NotSent)
  http_gun.stop(client)
}
