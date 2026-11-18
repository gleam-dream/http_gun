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
import gleam/time/duration
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

// Converts a stored cassette to schema 3: parse, then encode.
fn convert(
  text: String,
  max_bytes: Int,
) -> Result(String, cassette.CassetteError) {
  cassette.parse(text, max_bytes) |> result.map(cassette.encode)
}

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

@external(erlang, "http_gun_recording_fault_test_ffi", "staging_count")
fn staging_count(destination: String) -> Int

@external(erlang, "http_gun_recording_fault_test_ffi", "kill_recorder")
fn kill_recorder(recording: cassette.Recording) -> Nil

// Removal can follow the call that caused it (a killed writer, a crashed
// recorder), so the leak checks poll for a moment.
fn staging_removed(destination: String) -> Bool {
  staging_removed_within(destination, 200)
}

fn staging_removed_within(destination: String, tries: Int) -> Bool {
  case staging_count(destination), tries {
    0, _ -> True
    _, 0 -> False
    _, _ -> {
      process.sleep(10)
      staging_removed_within(destination, tries - 1)
    }
  }
}

pub fn real_record_finish_and_offline_replay_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  private_directory(destination) |> should.be_true
  let assert Ok(live) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Ok(destination))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Ok(destination))
  staging_count(destination) |> should.equal(0)
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
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.Busy))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  body.close(response.body)
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(cassette) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(cassette, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  let assert Error(failure) =
    body.next_within(response.body, duration.milliseconds(1000))
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
      cassette.options()
        // Room for the envelope only, so the first request does not fit.
        |> cassette.with_max_bytes(42),
    )
  let assert Ok(response) = http_gun.send(recorded.client, req(port))
  response.response.body |> should.equal(<<0, 255, 128>>)
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.CaptureLimit)))
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  staging_removed(destination) |> should.be_true
  http_gun.stop(recorded.client)
}

pub fn existing_destination_refusal_is_deterministic_test() {
  let port = server()
  let destination = store("existing bytes")
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  staging_removed(destination) |> should.be_true
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
  staging_count(destination) |> should.equal(0)
  emit(server, <<"3\r\nabc\r\n0\r\n\r\n":utf8>>)
  let assert Ok(collected) = body.collect(response.body, 1000)
  collected.bytes |> should.equal(<<"abc":utf8>>)
  body.close(response.body)
  cassette.finish(recorded.recording, duration.milliseconds(0))
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
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"a":utf8>>))
  break_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  body.close(response.body)
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(
    Error(
      cassette.CaptureFailed(cassette.IoFailure(
        cassette.OpenFile,
        cassette.IsDirectory,
      )),
    ),
  )
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  staging_removed(destination) |> should.be_true
  http_gun.stop(recorded.client)
}

pub fn stalled_writer_keeps_control_and_completed_http_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      local_config()
        |> config.with_request_timeout(config.After(duration.milliseconds(300))),
      destination,
      cassette.options(),
    )
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  emit(server, <<"1\r\na\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"a":utf8>>))
  let fifo = stall_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.Busy))
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.Interrupted)))
  release_fifo(fifo)
  staging_removed(destination) |> should.be_true
  body.close(response.body)
  http_gun.stop(recorded.client)
}

pub fn abort_removes_the_staging_directory_test() {
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  staging_count(destination) |> should.equal(1)
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  staging_count(destination) |> should.equal(0)
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.Interrupted)))
  cassette.load(destination, 10_000) |> should.equal(Error(cassette.Missing))
  http_gun.stop(recorded.client)
}

pub fn abort_with_exchanges_on_disk_removes_them_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  staging_count(destination) |> should.equal(0)
  http_gun.stop(recorded.client)
}

pub fn abort_after_a_failed_finish_leaves_nothing_test() {
  let port = server()
  let destination = store("existing bytes")
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Error(cassette.CaptureFailed(cassette.DestinationExists)))
  cassette.abort(recorded.recording) |> should.equal(Ok(Nil))
  staging_count(destination) |> should.equal(0)
  http_gun.stop(recorded.client)
  remove(destination)
}

pub fn owner_death_removes_the_staging_directory_test() {
  let destination = path()
  let started = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(recorded) =
        cassette.record(local_config(), destination, cassette.options())
      process.send(started, recorded)
      process.sleep_forever()
    })
  let assert Ok(recorded) = process.receive(started, 5000)
  let client = recorded.client
  staging_count(destination) |> should.equal(1)
  process.kill(owner)
  staging_removed(destination) |> should.be_true
  http_gun.stop(client)
}

pub fn recorder_crash_removes_the_staging_directory_test() {
  let port = server()
  let destination = path()
  let started = process.new_subject()
  // The recorder is linked to its owner, so the owner is a spare process.
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(recorded) =
        cassette.record(local_config(), destination, cassette.options())
      let assert Ok(_) = http_gun.send(recorded.client, req(port))
      process.send(started, recorded.client)
      kill_recorder(recorded.recording)
    })
  let assert Ok(client) = process.receive(started, 5000)
  staging_removed(destination) |> should.be_true
  http_gun.stop(client)
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
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Ok(destination))
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
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
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
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Ok(destination))
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
  body.next_within(reply.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  disconnect(server)
  let assert Error(failure) =
    body.next_within(reply.body, duration.milliseconds(1000))
  error.evidence(failure) |> should.equal(error.MaybeSent)
  body.close(reply.body)
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next_within(replay.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  body.next_within(replay.body, duration.milliseconds(1000))
  |> should.equal(Error(failure))
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
  cassette.finish(recorded.recording, duration.milliseconds(1))
  |> should.equal(Error(cassette.WaitTimeout))
  let assert Error(refused) = http_gun.send(recorded.client, req(port))
  error.evidence(refused) |> should.equal(error.NotSent)
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  body.close(response.body)
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  cassette.finish(recorded.recording, duration.milliseconds(0))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next_within(replay.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  let assert Error(failure) =
    body.next_within(replay.body, duration.milliseconds(1000))
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
  cassette.finish(recorded.recording, duration.milliseconds(1000))
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
  case cassette.finish(rec, duration.milliseconds(1)), tries {
    Error(actual), _ if actual == expected -> True
    _, 0 -> False
    _, _ -> wait_for_finish_result(rec, expected, tries - 1)
  }
}

fn wait_until_registered(
  rec: cassette.Recording,
) -> Result(String, cassette.FinishError) {
  case cassette.finish(rec, duration.milliseconds(10_000)) {
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
      body.next_within(response.body, duration.milliseconds(1000))
      |> should.equal(chunk(<<"abc":utf8>>))
      cancellation.cancel(token)
      let assert Error(failure) =
        body.next_within(response.body, duration.milliseconds(1000))
      error.reason(failure) |> should.equal(error.Cancelled)
      body.close(response.body)
      failure
    })
  closed(server) |> should.be_true
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"abc":utf8>>))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Error(failure))
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
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
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
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"data resp-SE":utf8>>))
  emit(server, <<"10\r\nCRET-value done.\r\n0\r\n\r\n":utf8>>)
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(chunk(<<"CRET-value done.":utf8>>))
  body.next_within(response.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.End([]))))
  body.close(response.body)
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
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

// Default redaction: an OAuth token exchange recorded with no configured
// redaction keeps none of its credentials.

fn token_exchange(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to(
      "http://localhost:"
      <> int.to_string(port)
      <> "/token?key=api-key-secret&page=2",
    )
  req
  |> request.set_method(http.Post)
  |> request.set_header(
    "content-type",
    "application/x-www-form-urlencoded; charset=utf-8",
  )
  |> request.set_header("x-auth-token", "header-token-secret")
  |> request.set_body(<<
    "grant_type=refresh_token&client_secret=client-secret-value&refresh_token=old-refresh-secret&scope=openid":utf8,
  >>)
}

const token_response =
  "{\"access_token\":\"access-secret-value\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"new-refresh-secret\",\"nested\":{\"id_token\":\"id-secret-value\"}}"

pub fn default_redaction_scrubs_token_exchange_from_recording_test() {
  let port =
    serve(bit_array.from_string(
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
      <> int.to_string(string.byte_size(token_response))
      <> "\r\n\r\n"
      <> token_response,
    ))
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, token_exchange(port))
  // The live response is untouched.
  live.response.body |> should.equal(bit_array.from_string(token_response))
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  list.each(
    [
      "api-key-secret", "header-token-secret", "client-secret-value",
      "old-refresh-secret", "access-secret-value", "new-refresh-secret",
      "id-secret-value",
    ],
    fn(secret) { string.contains(text, secret) |> should.be_false },
  )
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  let stored_request = testing.request(stored)
  stored_request.query |> should.equal(Some("key=REDACTED&page=2"))
  stored_request.body
  |> should.equal(<<
    "grant_type=refresh_token&client_secret=REDACTED&refresh_token=REDACTED&scope=openid":utf8,
  >>)
  let assert testing.Respond(stored_response, testing.Finished([])) =
    testing.reply(stored)
  stored_response.body
  |> should.equal([
    <<
      "{\"access_token\":\"REDACTED\",\"token_type\":\"Bearer\",\"expires_in\":3600,\"refresh_token\":\"REDACTED\",\"nested\":{\"id_token\":\"REDACTED\"}}":utf8,
    >>,
  ])

  // The redacted cassette still replays against the original live request.
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(replayed) = http_gun.send(client, token_exchange(port))
  replayed.response.status |> should.equal(200)
  http_gun.stop(client)
  remove(destination)
}

pub fn published_cassette_is_private_to_its_owner_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording, duration.milliseconds(1000))
  |> should.equal(Ok(destination))
  http_gun.stop(recorded.client)
  let assert Ok(info) = simplifile.file_info(destination)
  simplifile.file_info_permissions_octal(info) |> should.equal(0o600)
  remove(destination)
}

// A request-body rewrite normalises what the code sends; the answer the
// service gave is stored and replayed as it came.
fn normalise_times(bytes: BitArray) -> BitArray {
  case bit_array.to_string(bytes) {
    Ok(text) ->
      text
      |> string.replace("20/11 14:30", "<time>")
      |> string.replace("21/11 09:00", "<time>")
      |> bit_array.from_string
    Error(Nil) -> bytes
  }
}

pub fn request_body_rewrite_never_changes_a_recorded_answer_test() {
  let answer = "Vence dia 20/11 14:30"
  let port =
    serve(bit_array.from_string(
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "
      <> int.to_string(string.byte_size(answer))
      <> "\r\n\r\n"
      <> answer,
    ))
  let settings =
    local_config()
    |> config.with_redaction(
      redaction.default() |> redaction.with_request_body(normalise_times),
    )
  let asked = fn(time) {
    let assert Ok(req) =
      request.to("http://localhost:" <> int.to_string(port) <> "/ask")
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "text/plain")
    |> request.set_body(bit_array.from_string("Now is " <> time))
  }
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, asked("20/11 14:30"))
  live.response.body |> should.equal(bit_array.from_string(answer))
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).body |> should.equal(<<"Now is <time>":utf8>>)
  let assert testing.Respond(stored_response, _) = testing.reply(stored)
  bit_array.concat(stored_response.body)
  |> should.equal(bit_array.from_string(answer))

  // Another run sends another time; it still matches, and the code receives
  // the answer the service wrote.
  let assert Ok(client) = testing.playback(tape, settings)
  let assert Ok(replayed) = http_gun.send(client, asked("21/11 09:00"))
  replayed.response.body |> should.equal(bit_array.from_string(answer))
  testing.verify(client) |> should.equal(Ok(testing.Verdict([], [], [], 0)))
  http_gun.stop(client)
  remove(destination)
}

// A request header allow-list stores and compares only the named request
// headers and the content type. Credentials stay out even when named, and
// response headers keep the deny-list alone.
pub fn request_header_allow_list_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nX-Kept: yes\r\nX-Signature: resp-sig-secret\r\nContent-Length: 2\r\n\r\nok":utf8,
    >>)
  let settings =
    local_config()
    |> config.with_redaction(
      redaction.default()
      |> redaction.with_headers(["x-signature"])
      |> redaction.keeping_request_headers(["Accept"])
      |> redaction.keeping_request_headers(["x-goog-api-key", "x-signature"]),
    )
  let asked = fn(session) {
    let assert Ok(req) =
      request.to("http://localhost:" <> int.to_string(port) <> "/ask")
    req
    |> request.set_method(http.Post)
    |> request.set_header("accept", "text/plain")
    |> request.set_header("content-type", "text/plain")
    |> request.set_header("x-goog-api-key", "key-secret")
    |> request.set_header("x-signature", "sig-secret")
    |> request.set_header("x-session", session)
    |> request.set_body(<<"hello":utf8>>)
  }
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, asked("first-run"))
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  list.each(
    ["key-secret", "sig-secret", "first-run", "resp-sig-secret"],
    fn(leaked) { string.contains(text, leaked) |> should.be_false },
  )
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).headers
  |> should.equal([#("accept", "text/plain"), #("content-type", "text/plain")])
  let assert testing.Respond(stored_response, _) = testing.reply(stored)
  list.key_find(stored_response.headers, "x-kept") |> should.equal(Ok("yes"))
  list.key_find(stored_response.headers, "content-type")
  |> should.equal(Ok("text/plain"))

  // A listed request header takes part in matching; an unlisted one does not.
  let assert Ok(client) = testing.playback(tape, settings)
  let assert Error(changed) =
    http_gun.send(client, request.set_header(asked("x"), "accept", "*/*"))
  error.reason(changed) |> should.equal(error.PlaybackMismatch(0))
  let assert Ok(replayed) = http_gun.send(client, asked("second-run"))
  replayed.response.body |> should.equal(<<"ok":utf8>>)
  http_gun.stop(client)
  remove(destination)
}

// What a recording stores is what `cassette.redact` makes of the exchange
// the live client saw: one rule for the stored form.
pub fn recording_stores_what_redact_makes_of_the_live_exchange_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nX-Signature: resp-sig\r\nTransfer-Encoding: chunked\r\n\r\n9\r\n{\"token\":\r\n18\r\n\"t-1\",\"n\":\"20/11 14:30\"}\r\n0\r\nX-Signature: trailer-sig\r\nX-End: yes\r\n\r\n":utf8,
    >>)
  let policy =
    redaction.default()
    |> redaction.with_headers(["x-signature"])
    |> redaction.with_body(scrub)
    |> redaction.with_request_body(normalise_times)
    |> redaction.keeping_request_headers(["accept"])
  let settings = local_config() |> config.with_redaction(policy)
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/ask?token=t-2")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("accept", "application/json")
    |> request.set_header("x-session", "s-1")
    |> request.set_header("content-type", "application/x-www-form-urlencoded")
    |> request.set_body(<<"card=4111-1111&at=20/11 14:30&token=t-3":utf8>>)
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, req)
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let seen =
    testing.exchange(
      req,
      testing.Respond(
        response.Response(live.response.status, live.response.headers, [
          live.response.body,
        ]),
        testing.Finished(live.trailers),
      ),
    )
  let assert Ok(tape) = cassette.load(destination, 100_000)
  testing.exchanges(tape)
  |> should.equal(
    testing.exchanges(cassette.redact(testing.script([seen]), policy)),
  )
  // The values themselves: fields, then the body function, then the
  // request rewrite; trailers keep the deny-list alone.
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).body
  |> should.equal(<<"card=[card]&at=<time>&token=REDACTED":utf8>>)
  let assert testing.Respond(stored_response, testing.Finished(trailers)) =
    testing.reply(stored)
  trailers |> should.equal([#("x-end", "yes")])
  // The buffered JSON answer is rewritten by fields and the body function
  // only; its time stays as the service wrote it.
  stored_response.body
  |> should.equal([<<"{\"token\":\"REDACTED\",\"n\":\"20/11 14:30\"}":utf8>>])
  remove(destination)
}

pub fn verify_refuses_a_recording_client_test() {
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, cassette.options())
  testing.verify(recorded.client) |> should.equal(Error(testing.NotPlayback))
  let assert Ok(Nil) = cassette.abort(recorded.recording)
  http_gun.stop(recorded.client)
}

// A recorded schema 3 file is already in the codec's layout, and a streamed
// answer reads back byte for byte.
pub fn recorded_file_is_its_own_upgrade_test() {
  let port =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nTransfer-Encoding: chunked\r\n\r\n12\r\ndata: {\"a\":\"é\"}\n\n\r\nE\r\ndata: [DONE]\n\n\r\n0\r\nX-End: yes\r\n\r\n":utf8,
    >>)
  let settings = local_config()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let asked = fn() {
    let assert Ok(req) =
      request.to("http://localhost:" <> int.to_string(port) <> "/stream")
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(<<"{\n  \"prompt\": \"olá\"\n}\n":utf8>>)
  }
  let assert Ok(live) = http_gun.send(recorded.client, asked())
  // A name that does not resolve is recorded as a reject.
  let assert Error(live_failure) =
    http_gun.send(
      recorded.client,
      request.set_host(asked(), "127.0.0.1.invalid"),
    )
  // A JSON answer is held for redaction and stored as one chunk.
  let json_port =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 21\r\n\r\n{\n  \"token\": \"t-1\"\n}\n":utf8,
    >>)
  let assert Ok(json_req) =
    request.to("http://localhost:" <> int.to_string(json_port) <> "/json")
  let assert Ok(_) =
    http_gun.send(recorded.client, request.set_body(json_req, <<>>))
  // A body the client closes early is recorded as abandoned.
  let slow =
    serve(<<
      "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 100\r\n\r\npartial":utf8,
    >>)
  let assert Ok(slow_req) =
    request.to("http://localhost:" <> int.to_string(slow) <> "/slow")
  let assert Ok(opened) =
    http_gun.open(recorded.client, request.set_body(slow_req, <<>>))
  body.close(opened.body)
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  convert(text, 1_000_000) |> should.equal(Ok(text))
  string.contains(text, "\"data: [DONE]\"") |> should.be_true
  string.contains(text, "\"kind\": \"reject\"") |> should.be_true
  string.contains(text, "\"kind\": \"abandoned\"") |> should.be_true

  let assert Ok(tape) = cassette.load(destination, string.byte_size(text))
  let assert Ok(client) = testing.playback(tape, settings)
  let assert Ok(replayed) = http_gun.send(client, asked())
  replayed.response.body |> should.equal(live.response.body)
  replayed.trailers |> should.equal(live.trailers)
  // The reject replays as the failure the live client saw.
  let assert Error(replayed_failure) =
    http_gun.send(client, request.set_host(asked(), "127.0.0.1.invalid"))
  error.reason(replayed_failure) |> should.equal(error.reason(live_failure))
  http_gun.stop(client)
  remove(destination)
}

// The budget is charged on every byte the file holds: a budget that cannot
// hold the envelope is refused, and a recording within budget B loads with
// `max_bytes` B.
pub fn recording_budget_counts_stored_bytes_test() {
  cassette.record(
    local_config(),
    path(),
    cassette.options() |> cassette.with_max_bytes(41),
  )
  |> result.map(fn(recorded) { recorded.recording })
  |> should.equal(Error(cassette.CaptureLimit))

  let port = serve(<<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok":utf8>>)
  let destination = path()
  let budget = 2000
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      destination,
      cassette.options() |> cassette.with_max_bytes(budget),
    )
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)
  let assert Ok(text) = simplifile.read(destination)
  { string.byte_size(text) <= budget } |> should.be_true
  cassette.load(destination, budget) |> should.be_ok
  remove(destination)

  // The charge is the stored size exactly: a budget of the file's size
  // records it, one byte less does not.
  let exact = fn(budget) {
    let target = path()
    let assert Ok(recorded) =
      cassette.record(
        local_config(),
        target,
        cassette.options() |> cassette.with_max_bytes(budget),
      )
    let sent =
      http_gun.send(
        recorded.client,
        req(serve(<<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok":utf8>>)),
      )
    let finished =
      cassette.finish(recorded.recording, duration.milliseconds(1000))
    http_gun.stop(recorded.client)
    let assert Ok(_) = sent
    let size = case simplifile.read(target) {
      Ok(text) -> string.byte_size(text)
      Error(_) -> -1
    }
    remove(target)
    #(finished |> result.is_ok, size)
  }
  let assert #(True, stored) = exact(2000)
  exact(stored) |> should.equal(#(True, stored))
  exact(stored - 1) |> should.equal(#(False, -1))

  // An empty recording is the envelope alone and fits within its budget.
  let empty = path()
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      empty,
      cassette.options() |> cassette.with_max_bytes(42),
    )
  let assert Ok(_) = cassette.finish(recorded.recording, duration.seconds(1))
  http_gun.stop(recorded.client)
  cassette.load(empty, 42) |> should.be_ok
  remove(empty)
}

// With requests-only field redaction, a request's credential field is
// replaced and a JSON answer is stored exactly as received, chunk for chunk.
pub fn request_fields_only_keeps_answers_exact_test() {
  let port =
    serve(<<
      "HTTP/1.1 429 Too Many Requests\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\n\r\na\r\n{\"error\":{\r\nd\r\n\"code\":429}}\n\r\n0\r\n\r\n":utf8,
    >>)
  let policy = redaction.default() |> redaction.request_fields_only
  let settings = local_config() |> config.with_redaction(policy)
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/ask")
  let req =
    req
    |> request.set_method(http.Post)
    |> request.set_header("content-type", "application/json")
    |> request.set_body(<<"{\"token\":\"t-1\",\"q\":1}":utf8>>)
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings, destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, req)
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).body
  |> should.equal(<<"{\"token\":\"REDACTED\",\"q\":1}":utf8>>)
  let assert testing.Respond(stored_response, _) = testing.reply(stored)
  // The chunks are as the transport delivered them; their bytes are the
  // answer as sent.
  bit_array.concat(stored_response.body)
  |> should.equal(<<"{\"error\":{\"code\":429}}\n":utf8>>)

  let assert Ok(client) = testing.playback(tape, settings)
  let assert Ok(replayed) = http_gun.send(client, req)
  replayed.response.status |> should.equal(429)
  replayed.response.body |> should.equal(live.response.body)
  http_gun.stop(client)
  remove(destination)
}
