import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/destination
import http_gun/error
import http_gun/request_options

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

fn settings() -> config.Config {
  let c = config.default()
  config.Config(
    ..c,
    deadline_ms: 1000,
    destination: destination.Policy(..c.destination, allow_loopback: True),
  )
}

fn req(port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host("127.0.0.1")
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

pub fn main() {
  let _ = dependency_header_limit_remains_typed_test()
}

pub fn dependency_header_limit_remains_typed_test() {
  let assert Ok(client) = http_gun.start(settings())
  let bytes =
    "HTTP/1.1 200 OK\r\n"
    <> string.repeat("X-Test: a\r\n", 200)
    <> "Content-Length: 0\r\n\r\n"
  let outcome = http_gun.send(client, req(serve(bit_array.from_string(bytes))))
  let _ = http_gun.stop(client)
  outcome
  |> should.equal(
    Error(error.Failure(
      error.RequestFailed(error.HeaderLimitReached),
      error.MayHaveBeenSent,
    )),
  )
}

pub fn response_controls_are_rejected_test() {
  let assert Ok(client) = http_gun.start(settings())
  list.each([0, 1, 10, 31, 127], fn(byte) {
    let port =
      serve(<<
        "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Test: a":utf8,
        byte,
        "b\r\n\r\n":utf8,
      >>)
    let actual = http_gun.send(client, req(port))
    actual
    |> should.equal(
      Error(error.Failure(
        error.RequestFailed(error.ProtocolError),
        error.MayHaveBeenSent,
      )),
    )
  })
  let _ = http_gun.stop(client)
}

pub fn strict_framing_dependency_cases_test() {
  let assert Ok(client) = http_gun.start(settings())
  list.each(
    [
      "HTTP/1.1 200 OK\nContent-Length: 0\n\n",
      "HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx",
      "HTTP/1.1 200 OK\r\nContent-Length: -1\r\n\r\nx",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n",
      "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\nx1\r\nx\r\n0\r\n\r\n",
    ],
    fn(bytes) {
      let assert Error(failure) =
        http_gun.send(client, req(serve(bit_array.from_string(bytes))))
      failure.evidence |> should.equal(error.MayHaveBeenSent)
    },
  )
  let _ = http_gun.stop(client)
}

// Explicitly accepted dependency exception: Gun discards reason text, so it
// cannot be validated at HTTP Gun's supported response-message boundary.
pub fn reason_phrase_is_not_exposed_by_gun_test() {
  let assert Ok(client) = http_gun.start(settings())
  let port =
    serve(<<"HTTP/1.1 200 O":utf8, 1, "K\r\nContent-Length: 0\r\n\r\n":utf8>>)
  let assert Ok(reply) = http_gun.send(client, req(port))
  reply.response.status |> should.equal(200)
  let _ = http_gun.stop(client)
}

pub fn entire_parsed_head_including_final_header_is_limited_test() {
  let c = settings()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, limits: config.Limits(..c.limits, head_bytes: 32)),
    )
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-One: 1234567890\r\nX-Two: 1234567890\r\n\r\n":utf8,
    >>)
  let assert Error(failure) = http_gun.send(client, req(port))
  failure.reason
  |> should.equal(error.LimitExceeded(error.ResponseHeaderBytes, 32, 45))
  let _ = http_gun.stop(client)
}

pub fn ipv6_authority_is_always_bracketed_test() {
  let request =
    req(443) |> request.set_scheme(http.Https) |> request.set_host("::1")
  body.authority(request) |> should.equal("[::1]")
  body.authority(request.Request(..request, port: Some(8443)))
  |> should.equal("[::1]:8443")
  body.authority(request.Request(..request, host: "[::1]"))
  |> should.equal("[::1]")
  // The authority is independent of the port number and uses the original name.
  body.authority(req(80) |> request.set_host("localhost"))
  |> should.equal("localhost")
  body.authority(req(8080) |> request.set_host("localhost"))
  |> should.equal("localhost:" <> int.to_string(8080))
}

@external(erlang, "http_gun_destination_test_ffi", "sink")
fn sink(tls: Bool, warm: Bool) -> #(Int, process.Pid)

@external(erlang, "http_gun_destination_test_ffi", "await_sink")
fn await_sink(pid: process.Pid) -> Nil

@external(erlang, "http_gun_destination_test_ffi", "stop_sink")
fn stop_sink(pid: process.Pid) -> Nil

@external(erlang, "http_gun_destination_test_ffi", "mailbox_size")
fn mailbox_size() -> Int

@external(erlang, "http_gun_destination_test_ffi", "payload")
fn payload(size: Int) -> BitArray

@external(erlang, "http_gun_ffi", "now")
fn now() -> Int

pub fn stalled_sends_end_and_leave_no_caller_messages_test() {
  list.each(
    [#(False, False), #(True, False), #(False, True), #(True, True)],
    fn(row) {
      let baseline = mailbox_size()
      let c = settings()
      let c =
        config.Config(
          ..c,
          deadline_ms: 5000,
          trust: config.CustomCa("test/fixtures/ip_ca.crt"),
          limits: config.Limits(..c.limits, request_bytes: 16_777_216),
        )
      let assert Ok(client) = http_gun.start(c)
      let #(port, server) = sink(row.0, row.1)
      let request =
        req(port)
        |> request.set_scheme(case row.0 {
          True -> http.Https
          False -> http.Http
        })
      case row.1 {
        True -> {
          let assert Ok(_) = http_gun.send(client, request)
          Nil
        }
        False -> Nil
      }
      let bytes = payload(16_777_216)
      let assert Ok(budget) = deadline.after(300)
      let before = now()
      let assert Error(failure) =
        http_gun.send_with_options(
          client,
          request |> request.set_method(http.Post) |> request.set_body(bytes),
          request_options.Options(
            ..request_options.default(),
            deadline: Some(budget),
          ),
        )
      let elapsed = now() - before
      failure.evidence |> should.equal(error.MayHaveBeenSent)
      failure.reason |> should.equal(error.DeadlineExceeded)
      { elapsed < 1500 } |> should.be_true
      await_sink(server)
      let _ = http_gun.stop(client)
      let cleanup_elapsed = now() - before
      stop_sink(server)
      { cleanup_elapsed < 1500 } |> should.be_true
      mailbox_size() |> should.equal(baseline)
    },
  )
}

@external(erlang, "http_gun_destination_test_ffi", "echo_authority")
fn echo_authority(ipv6: Bool) -> Int

pub fn pinned_ip_keeps_original_http_authority_test() {
  let assert Ok(client) = http_gun.start(settings())
  let port = echo_authority(False)
  let assert Ok(reply) =
    http_gun.send(client, req(port) |> request.set_host("localhost"))
  reply.response.body
  |> should.equal(bit_array.from_string("localhost:" <> int.to_string(port)))
  let port = echo_authority(True)
  let assert Ok(request) = request.to("http://[::1]:" <> int.to_string(port))
  let assert Ok(reply) =
    http_gun.send(client, request |> request.set_body(<<>>))
  reply.response.body
  |> should.equal(bit_array.from_string("[::1]:" <> int.to_string(port)))
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn await_closed(server: process.Pid) -> Bool

pub fn cancellation_and_body_deadline_leave_long_lived_caller_clean_test() {
  list.each([True, False], fn(cancel) {
    let c = settings()
    let assert Ok(client) = http_gun.start(config.Config(..c, deadline_ms: 300))
    let #(port, server) = controlled()
    let finished = process.new_subject()
    let inspect = process.new_subject()
    let ready = process.new_subject()
    let assert Ok(Nil) =
      cancellation.with_token(fn(token) {
        let _ =
          process.spawn_unlinked(fn() {
            let probe = process.new_subject()
            let assert Ok(response) =
              http_gun.open_with_options(
                client,
                req(port),
                request_options.Options(
                  ..request_options.default(),
                  cancellation: Some(token),
                ),
              )
            process.send(ready, probe)
            let result = body.next(response.body, 1000)
            let _ = body.close(response.body)
            process.send(finished, result)
            let assert Ok(Nil) = process.receive(probe, 2000)
            process.send(inspect, mailbox_size())
          })
        await_request(server)
        let assert Ok(probe) = process.receive(ready, 1000)
        case cancel {
          True -> cancellation.cancel(token)
          False -> Nil
        }
        let assert Ok(Error(failure)) = process.receive(finished, 1500)
        failure.reason
        |> should.equal(case cancel {
          True -> error.Cancelled
          False -> error.DeadlineExceeded
        })
        await_closed(server) |> should.be_true
        let _ = http_gun.stop(client)
        process.send(probe, Nil)
        process.receive(inspect, 1000) |> should.equal(Ok(0))
      })
  })
}
