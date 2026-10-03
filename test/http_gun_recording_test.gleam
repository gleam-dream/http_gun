import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/redaction
import http_gun/testing
import simplifile

@external(erlang, "http_gun_test_server", "start")
fn server() -> Int

@external(erlang, "http_gun_test_server", "serve")
fn serve(response: BitArray) -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

@external(erlang, "http_gun_recording_fault_test_ffi", "private")
fn private_directory(path: String) -> Bool

pub fn real_record_finish_and_offline_replay_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  private_directory(destination) |> should.be_true
  let assert Ok(live) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, 0) |> should.equal(Ok(destination))
  cassette.finish(recorded.recording, 0) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(value) = cassette.load(destination, 10_000)
  let assert Ok(playback) = testing.playback(value, local_config())
  let assert Ok(replayed) = http_gun.send(playback, req(port))
  replayed.response |> should.equal(live.response)
  replayed.trailers |> should.equal(live.trailers)
  http_gun.stop(playback)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "send_control")
fn emit(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

@external(erlang, "http_gun_scope_test_ffi", "fixture")
fn store(contents: String) -> String

fn chunk(bytes: BitArray) -> Result(option.Option(body.Event), error.Failure) {
  Ok(Some(body.Chunk(bytes)))
}

pub fn early_cancel_records_without_draining_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  cassette.finish(recorded.recording, 0) |> should.equal(Error(cassette.Busy))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  body.close(response.body)
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(cassette) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(cassette, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  let assert Error(failure) = body.next_within(response.body, 1000)
  error.reason(failure) |> should.equal(error.Closed)
  body.close(response.body)
  http_gun.stop(client)
  remove(destination)
}

pub fn capture_budget_failure_preserves_http_outcome_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      destination,
      cassette.options() |> cassette.with_max_bytes(1),
    )
  let assert Ok(response) = http_gun.send(recorded.client, req(port))
  response.response.body |> should.equal(<<0, 255, 128>>)
  cassette.finish(recorded.recording, 0)
  |> should.equal(Error(cassette.CaptureFailed(cassette.CaptureLimit)))
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  http_gun.stop(recorded.client)
}

pub fn existing_destination_refusal_is_deterministic_test() {
  let port = server()
  let destination = store("existing bytes")
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, 0)
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  cassette.finish(recorded.recording, 0)
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  http_gun.stop(recorded.client)
  remove(destination)
}

pub fn interrupted_capture_never_publishes_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  emit(server, <<"3\r\nabc\r\n0\r\n\r\n":utf8>>)
  let assert Ok(collected) = body.collect(response.body, 1000)
  collected.bytes |> should.equal(<<"abc":utf8>>)
  body.close(response.body)
  cassette.finish(recorded.recording, 0)
  |> should.equal(Error(cassette.CaptureFailed(cassette.Interrupted)))
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  http_gun.stop(recorded.client)
}

@external(erlang, "http_gun_recording_fault_test_ffi", "break_file")
fn break_file(destination: String) -> Nil

@external(erlang, "http_gun_recording_fault_test_ffi", "stall_file")
fn stall_file(destination: String) -> String

@external(erlang, "http_gun_recording_fault_test_ffi", "release")
fn release_fifo(path: String) -> Nil

pub fn actual_write_failure_does_not_replace_http_result_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  emit(server, <<"1\r\na\r\n":utf8>>)
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"a":utf8>>))
  break_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  body.close(response.body)
  cassette.finish(recorded.recording, 0)
  |> should.equal(
    Error(
      cassette.CaptureFailed(cassette.IoFailure(
        cassette.OpenFile,
        cassette.IsDirectory,
      )),
    ),
  )
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  http_gun.stop(recorded.client)
}

pub fn stalled_writer_keeps_control_and_completed_http_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      local_config() |> config.with_request_timeout(config.Milliseconds(300)),
      destination,
      cassette.options(),
    )
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  emit(server, <<"1\r\na\r\n":utf8>>)
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"a":utf8>>))
  let fifo = stall_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  cassette.finish(recorded.recording, 0) |> should.equal(Error(cassette.Busy))
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  cassette.finish(recorded.recording, 0)
  |> should.equal(Error(cassette.CaptureFailed(cassette.Interrupted)))
  release_fifo(fifo)
  body.close(response.body)
  http_gun.stop(recorded.client)
}

pub fn explicit_replacement_and_finalized_refusal_test() {
  let port = server()
  let destination = store("old")
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      destination,
      cassette.options() |> cassette.replace_existing,
    )
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, 0) |> should.equal(Ok(destination))
  cassette.load(destination, 10_000) |> should.be_ok
  let assert Error(failure) = http_gun.send(recorded.client, req(port))
  error.evidence(failure) |> should.equal(error.NotSent)
  error.reason(failure) |> should.equal(error.RecordingClosed)
  http_gun.stop(recorded.client)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

pub fn cancelled_before_headers_records_without_inventing_response_test() {
  let #(port, server) = gated()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(reply, http_gun.open(recorded.client, req(port)))
    })
  await_request(server)
  http_gun.stop(recorded.client)
  let assert Ok(Error(live)) = process.receive(reply, 1000)
  error.reason(live) |> should.equal(error.Closed)
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  let assert Ok(value) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(value, local_config())
  let assert Error(replayed) = http_gun.open(client, req(port))
  replayed |> should.equal(live)
  http_gun.stop(client)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

pub fn concurrent_recording_and_replay_test() {
  let port = persistent()
  let destination = path()
  let requests = list.repeat(req(port), 30)
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(live) = http_gun.batch(recorded.client, requests, 10)
  list.all(live, result.is_ok) |> should.be_true
  cassette.finish(recorded.recording, 0) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(value) = cassette.load(destination, 100_000)
  let assert Ok(client) = testing.playback(value, local_config())
  let assert Ok(replayed) = http_gun.batch(client, requests, 10)
  list.all(replayed, result.is_ok) |> should.be_true
  http_gun.stop(client)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "disconnect")
fn disconnect(server: process.Pid) -> Nil

pub fn recorded_failure_retains_observed_prefix_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(reply) = http_gun.open(recorded.client, req(port))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(reply.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  disconnect(server)
  let assert Error(failure) = body.next_within(reply.body, 1000)
  error.evidence(failure) |> should.equal(error.MaybeSent)
  body.close(reply.body)
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next_within(replay.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  body.next_within(replay.body, 1000) |> should.equal(Error(failure))
  body.close(replay.body)
  http_gun.stop(client)
  remove(destination)
}

// DESIGN E1: timeout seals capture but neither drains nor cancels HTTP.
pub fn finish_wait_timeout_then_cancel_and_publish_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  // A positive wait seals the capture; an immediate finish would only refuse.
  cassette.finish(recorded.recording, 1)
  |> should.equal(Error(cassette.WaitTimeout))
  let assert Error(refused) = http_gun.send(recorded.client, req(port))
  error.evidence(refused) |> should.equal(error.NotSent)
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  body.close(response.body)
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  cassette.finish(recorded.recording, 0) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next_within(replay.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  let assert Error(failure) = body.next_within(replay.body, 1000)
  error.reason(failure) |> should.equal(error.Closed)
  body.close(replay.body)
  http_gun.stop(client)
  remove(destination)
}

pub fn finish_wait_contention_death_and_abort_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  let waiter =
    process.spawn_unlinked(fn() {
      let _ = wait_until_registered(recorded.recording)
      Nil
    })
  wait_for_finish_result(recorded.recording, cassette.Busy, 1000)
  |> should.be_true
  process.kill(waiter)
  wait_for_finish_result(recorded.recording, cassette.WaitTimeout, 1000)
  |> should.be_true
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  cassette.finish(recorded.recording, 1000)
  |> should.equal(Error(cassette.CaptureFailed(cassette.Interrupted)))
  body.close(response.body)
  closed(server) |> should.be_true
  http_gun.stop(recorded.client)
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
}

// A short positive wait registers as the waiter, so it sees contention
// (`Busy`) while another waiter is registered and `WaitTimeout` otherwise.
fn wait_for_finish_result(
  rec: cassette.Recording,
  expected: cassette.FinishError,
  tries: Int,
) -> Bool {
  case cassette.finish(rec, 1), tries {
    Error(actual), _ if actual == expected -> True
    _, 0 -> False
    _, _ -> wait_for_finish_result(rec, expected, tries - 1)
  }
}

fn wait_until_registered(
  rec: cassette.Recording,
) -> Result(String, cassette.FinishError) {
  case cassette.finish(rec, 10_000) {
    Error(cassette.Busy) -> wait_until_registered(rec)
    result -> result
  }
}

pub fn token_cancellation_preserves_typed_outcome_on_replay_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let failure =
    cancellation.with_token(fn(token) {
      let assert Ok(response) =
        recorded.client
        |> http_gun.with_cancellation(token)
        |> http_gun.open(req(port))
      emit(server, <<"3\r\nabc\r\n":utf8>>)
      body.next_within(response.body, 1000)
      |> should.equal(chunk(<<"abc":utf8>>))
      cancellation.cancel(token)
      let assert Error(failure) = body.next_within(response.body, 1000)
      error.reason(failure) |> should.equal(error.Cancelled)
      body.close(response.body)
      failure
    })
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next_within(response.body, 1000) |> should.equal(chunk(<<"abc":utf8>>))
  body.next_within(response.body, 1000) |> should.equal(Error(failure))
  body.close(response.body)
  http_gun.stop(client)
  remove(destination)
}

// Configured redaction: what the recording stores, and what playback
// compares.

fn scrub(bytes: BitArray) -> BitArray {
  case bit_array.to_string(bytes) {
    Ok(text) ->
      text
      |> string.replace("card=4111-1111", "card=[card]")
      |> string.replace("resp-SECRET-value", "[secret]")
      |> bit_array.from_string
    Error(Nil) -> bytes
  }
}

fn redacting_config() -> config.Config {
  local_config()
  |> config.with_redaction(
    redaction.default()
    |> redaction.with_headers(["X-Signature"])
    |> redaction.with_query_parameters(["token"])
    |> redaction.with_body(scrub),
  )
}

const query = "a=1&token=tok-secret-1&b=x%20y&tokens=keep&token=tok-secret-2&c"

fn secret_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to(
      "http://localhost:" <> int.to_string(port) <> "/resource?" <> query,
    )
  req
  |> request.set_method(http.Post)
  |> request.set_header("x-signature", "sig-secret")
  |> request.set_header("authorization", "Bearer auth-secret")
  |> request.set_header("accept", "text/plain")
  |> request.set_body(<<"card=4111-1111&amount=5":utf8>>)
}

pub fn redaction_removes_headers_and_query_values_from_recording_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nX-Signature: resp-sig-secret\r\nX-Kept: yes\r\nTransfer-Encoding: chunked\r\n\r\n2\r\nok\r\n0\r\nX-Signature: trailer-sig-secret\r\nX-End: yes\r\n\r\n":utf8,
    >>)
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(redacting_config(), destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, secret_request(port))
  // The live response is untouched.
  response.get_header(live.response, "x-signature")
  |> should.equal(Ok("resp-sig-secret"))
  live.trailers
  |> should.equal([#("x-signature", "trailer-sig-secret"), #("x-end", "yes")])
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  list.each(
    [
      "sig-secret", "resp-sig-secret", "trailer-sig-secret", "auth-secret",
      "tok-secret-1", "tok-secret-2",
    ],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  let stored_request = testing.request(stored)
  // The named parameter keeps its name; every other byte of the query stays.
  stored_request.query
  |> should.equal(Some(
    "a=1&token=REDACTED&b=x%20y&tokens=keep&token=REDACTED&c",
  ))
  stored_request.headers |> should.equal([#("accept", "text/plain")])
  let assert testing.Respond(stored_response, testing.Finished(trailers)) =
    testing.reply(stored)
  list.key_find(stored_response.headers, "x-signature")
  |> should.equal(Error(Nil))
  list.key_find(stored_response.headers, "x-kept") |> should.equal(Ok("yes"))
  trailers |> should.equal([#("x-end", "yes")])

  // Playback applies the same redaction to the incoming request, so the
  // original live request matches.
  let assert Ok(client) = testing.playback(tape, redacting_config())
  let assert Ok(replayed) = http_gun.send(client, secret_request(port))
  replayed.response.body |> should.equal(<<"ok":utf8>>)
  response.get_header(replayed.response, "x-signature")
  |> should.equal(Error(Nil))
  http_gun.stop(client)
  remove(destination)
}

pub fn body_redaction_sees_a_secret_split_across_chunks_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(redacting_config(), destination, cassette.options())
  let assert Ok(response) = http_gun.open(recorded.client, secret_request(port))
  // The secret arrives in two chunks, each read separately.
  emit(server, <<"c\r\ndata resp-SE\r\n":utf8>>)
  body.next_within(response.body, 1000)
  |> should.equal(chunk(<<"data resp-SE":utf8>>))
  emit(server, <<"10\r\nCRET-value done.\r\n0\r\n\r\n":utf8>>)
  body.next_within(response.body, 1000)
  |> should.equal(chunk(<<"CRET-value done.":utf8>>))
  body.next_within(response.body, 1000)
  |> should.equal(Ok(Some(body.End([]))))
  body.close(response.body)
  cassette.finish(recorded.recording, 1000) |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  list.each(
    ["4111-1111", "resp-SECRET-value", "resp-SE", "CRET-value", "sig-secret"],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).body |> should.equal(<<"card=[card]&amount=5":utf8>>)
  let assert testing.Respond(stored_response, testing.Finished([])) =
    testing.reply(stored)
  // The whole response body is rewritten and stored as one chunk.
  stored_response.body |> should.equal([<<"data [secret] done.":utf8>>])

  // The redacted cassette replays against the original live request.
  let assert Ok(client) = testing.playback(tape, redacting_config())
  let assert Ok(replayed) = http_gun.send(client, secret_request(port))
  replayed.response.body |> should.equal(<<"data [secret] done.":utf8>>)
  http_gun.stop(client)

  // Without the redaction, the original request no longer matches the
  // stored one.
  let assert Ok(plain) = testing.playback(tape, local_config())
  let assert Error(mismatch) = http_gun.send(plain, secret_request(port))
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(0))
  http_gun.stop(plain)
  remove(destination)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
