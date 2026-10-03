import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "send_control")
fn emit(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

@external(erlang, "http_gun_measure_ffi", "now")
fn now_us() -> Int

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn reason_and_evidence(
  outcome: Result(a, error.Failure),
) -> Result(a, #(error.Reason, error.Evidence)) {
  result.map_error(outcome, fn(failure) {
    #(error.reason(failure), error.evidence(failure))
  })
}

pub fn local_timeout_preserves_stream_and_copies_share_cursor_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  let copy = response.body
  // A local wait that passes is not a failure: the stream stays intact.
  body.next_within(copy, duration.milliseconds(0)) |> should.equal(Ok(None))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(<<"abc":utf8>>))))
  body.close(copy)
  body.close(response.body)
  closed(server) |> should.be_true
  http_gun.stop(client)
}

pub fn next_within_returns_none_and_stream_continues_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  let started = now_us()
  body.next_within(response.body, duration.milliseconds(50))
  |> should.equal(Ok(None))
  { now_us() - started >= 50_000 } |> should.be_true
  body.next_within(response.body, duration.milliseconds(50))
  |> should.equal(Ok(None))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(<<"abc":utf8>>))))
  body.next_within(response.body, duration.milliseconds(50))
  |> should.equal(Ok(None))
  emit(server, <<"2\r\nde\r\n0\r\n\r\n":utf8>>)
  body.next(response.body) |> should.equal(Ok(body.Chunk(<<"de":utf8>>)))
  body.next(response.body) |> should.equal(Ok(body.End([])))
  body.close(response.body)
  http_gun.stop(client)
}

pub fn idle_timeout_fails_stalled_read_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_idle_timeout(config.After(duration.milliseconds(100))),
    )
  let assert Ok(response) = http_gun.open(client, req(port))
  let started = now_us()
  let assert Error(failure) = body.next(response.body)
  let waited = now_us() - started
  error.reason(failure) |> should.equal(error.IdleTimeout)
  error.evidence(failure) |> should.equal(error.MaybeSent)
  error.kind(failure) |> should.equal(error.TimedOut)
  error.status(failure) |> should.equal(Some(200))
  { waited >= 90_000 && waited < 2_000_000 } |> should.be_true
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

pub fn view_idle_timeout_replaces_client_idle_timeout_test() {
  let #(port, server) = controlled()
  // The client's own idle timeout is the 30 s default.
  let assert Ok(client) = http_gun.start(local_config())
  let impatient =
    client
    |> http_gun.with_idle_timeout(config.After(duration.milliseconds(100)))
  let assert Ok(response) = http_gun.open(impatient, req(port))
  let assert Error(failure) = body.next(response.body)
  error.reason(failure) |> should.equal(error.IdleTimeout)
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

pub fn paused_reader_is_not_failed_by_idle_timeout_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_idle_timeout(config.After(duration.milliseconds(100))),
    )
  let assert Ok(response) = http_gun.open(client, req(port))
  // Not reading for three idle periods is a pause, not idleness.
  process.sleep(300)
  // The idle period counts from the start of this wait, so a shorter wait
  // passes without failure.
  body.next_within(response.body, duration.milliseconds(30))
  |> should.equal(Ok(None))
  process.sleep(300)
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(<<"abc":utf8>>))))
  emit(server, <<"0\r\n\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.End([]))))
  body.close(response.body)
  http_gun.stop(client)
}

pub fn overall_deadline_is_terminal_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(100))),
    )
  let assert Ok(response) = http_gun.open(client, req(port))
  let assert Error(failure) =
    body.next_within(response.body, duration.milliseconds(1000))
  #(error.reason(failure), error.evidence(failure))
  |> should.equal(#(error.DeadlineExceeded, error.MaybeSent))
  error.status(failure) |> should.equal(Some(200))
  body.next_within(response.body, duration.milliseconds(1000))
  |> reason_and_evidence
  |> should.equal(Error(#(error.DeadlineExceeded, error.MaybeSent)))
  closed(server) |> should.be_true
  body.close(response.body)
  http_gun.stop(client)
}

pub fn owner_death_closes_socket_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(response) = http_gun.open(client, req(port))
      process.send(ready, response.body)
      process.sleep_forever()
    })
  let assert Ok(stream) = process.receive(ready, 1000)
  body.next_within(stream, duration.milliseconds(1))
  |> reason_and_evidence
  |> should.equal(Error(#(error.WrongOwner, error.MaybeSent)))
  process.kill(owner)
  closed(server) |> should.be_true
  http_gun.stop(client)
}

pub fn buffered_limit_closes_socket_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_response_body_bytes(2))
  let response = http_gun.open(client, req(port))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  let assert Ok(response) = response
  let assert Error(failure) = body.collect(response.body, 2)
  error.reason(failure)
  |> should.equal(error.LimitExceeded(error.ResponseBodyBytes, 2, 3))
  error.evidence(failure) |> should.equal(error.MaybeSent)
  // The oversized body's failure carries the response status.
  error.status(failure) |> should.equal(Some(200))
  closed(server) |> should.be_true
  http_gun.stop(client)
}

@external(erlang, "http_gun_scope_test_ffi", "raised")
fn raised(run: fn() -> a) -> Bool

@external(erlang, "erlang", "error")
fn raise(reason: ScopeProbe) -> Nil

type ScopeProbe {
  ScopeProbe
}

pub fn exception_scope_cleanup_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  raised(fn() {
    use _ <- http_gun.with_response(client, req(port), fn(f) { f })
    raise(ScopeProbe)
    Ok(Nil)
  })
  |> should.be_true
  closed(server) |> should.be_true
  http_gun.stop(client)
}

pub fn scoped_early_exit_closes_socket_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  {
    use _ <- http_gun.with_response(client, req(port), fn(f) { f })
    Ok("caller value")
  }
  |> should.equal(Ok("caller value"))
  closed(server) |> should.be_true
  http_gun.stop(client)
}

pub fn conflicting_reader_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let ready = process.new_subject()
  let reading = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let assert Ok(response) = http_gun.open(client, req(port))
      process.send(ready, #(response.body, command))
      let assert Ok(Nil) = process.receive(command, 1000)
      process.send(reading, Nil)
      process.send(
        finished,
        body.next_within(response.body, duration.milliseconds(2000)),
      )
    })
  let assert Ok(#(stream, command)) = process.receive(ready, 1000)
  process.send(command, Nil)
  let assert Ok(Nil) = process.receive(reading, 1000)
  await_conflict(stream, 1000) |> should.be_true
  body.close(stream)
  let assert Ok(_) = process.receive(finished, 1000)
  closed(server) |> should.be_true
  http_gun.stop(client)
}

fn await_conflict(stream: body.Body, remaining: Int) -> Bool {
  case remaining {
    0 -> False
    _ ->
      case body.next_within(stream, duration.milliseconds(0)) {
        Error(failure) ->
          case error.reason(failure) {
            error.ReadConflict -> True
            error.WrongOwner -> await_conflict(stream, remaining - 1)
            _ -> False
          }
        _ -> False
      }
  }
}

type ConsumerError {
  Http(error.Failure)
  ApplicationStopped
}

pub fn fallible_scope_preserves_application_error_and_cleanup_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  http_gun.with_response(client, req(port), Http, fn(_) {
    Error(ApplicationStopped)
  })
  |> should.equal(Error(ApplicationStopped))
  closed(server) |> should.be_true
  http_gun.stop(client)
}

// A read failure maps through the callback's own error type; an opening
// failure maps through `on_failure`.
pub fn fallible_scope_maps_open_and_read_failures_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let impatient =
    client
    |> http_gun.with_idle_timeout(config.After(duration.milliseconds(50)))
  let assert Error(Http(failure)) =
    http_gun.with_response(impatient, req(port), Http, fn(response) {
      body.next(response.body) |> result.map_error(Http)
    })
  error.reason(failure) |> should.equal(error.IdleTimeout)
  error.evidence(failure) |> should.equal(error.MaybeSent)
  closed(server) |> should.be_true
  http_gun.stop(client)
  let assert Error(Http(closed_failure)) =
    http_gun.with_response(client, req(port), Http, fn(_) { Ok(Nil) })
  error.reason(closed_failure) |> should.equal(error.ClientClosed)
}

pub fn fallible_scope_success_and_exception_cleanup_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  http_gun.with_response(client, req(port), Http, fn(_) { Ok("value") })
  |> should.equal(Ok("value"))
  closed(server) |> should.be_true
  let #(port, server) = controlled()
  raised(fn() {
    http_gun.with_response(client, req(port), Http, fn(_) {
      raise(ScopeProbe)
      Ok(Nil)
    })
  })
  |> should.be_true
  closed(server) |> should.be_true
  http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
