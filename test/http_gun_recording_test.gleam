import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/recording
import http_gun/request_options

@external(erlang, "http_gun_test_server", "start")
fn server() -> Int

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
    cassette.record(local_config(), destination, recording.default())
  private_directory(destination) |> should.be_true
  let assert Ok(live) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording) |> should.equal(Ok(destination))
  cassette.finish(recorded.recording) |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(value) = cassette.load(destination, 10_000)
  let assert Ok(playback) = cassette.playback(value, local_config())
  let assert Ok(replayed) = http_gun.send(playback, req(port))
  replayed.response |> should.equal(live.response)
  replayed.trailers |> should.equal(live.trailers)
  let _ = http_gun.stop(playback)
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

pub fn early_cancel_records_without_draining_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  cassette.finish(recorded.recording) |> should.equal(Error(recording.Busy))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  let _ = body.close(response.body)
  closed(server) |> should.be_true
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(cassette) = cassette.load(destination, 10_000)
  let assert Ok(client) = cassette.playback(cassette, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  let assert Error(failure) = body.next(response.body, 1000)
  failure.reason |> should.equal(error.Closed)
  let _ = body.close(response.body)
  let _ = http_gun.stop(client)
  remove(destination)
}

pub fn capture_budget_failure_preserves_http_outcome_test() {
  let port = server()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      destination,
      recording.Options(1, recording.RefuseExisting),
    )
  let assert Ok(response) = http_gun.send(recorded.client, req(port))
  response.response.body |> should.equal(<<0, 255, 128>>)
  cassette.finish(recorded.recording)
  |> should.equal(Error(recording.CaptureFailed(recording.CaptureLimit)))
  let assert Error(missing) = cassette.load(destination, 10_000)
  missing.reason |> should.equal(error.FixtureMissing)
  let _ = http_gun.stop(recorded.client)
}

pub fn existing_destination_refusal_is_deterministic_test() {
  let port = server()
  let destination = store("existing bytes")
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording)
  |> should.equal(Error(recording.CaptureFailed(recording.DestinationExists)))
  cassette.finish(recorded.recording)
  |> should.equal(Error(recording.CaptureFailed(recording.DestinationExists)))
  let _ = http_gun.stop(recorded.client)
  remove(destination)
}

pub fn interrupted_capture_never_publishes_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  recording.abort(recorded.recording) |> should.equal(Ok(Nil))
  emit(server, <<"3\r\nabc\r\n0\r\n\r\n":utf8>>)
  let assert Ok(collected) = body.collect(response.body, 1000)
  collected.bytes |> should.equal(<<"abc":utf8>>)
  let _ = body.close(response.body)
  cassette.finish(recorded.recording)
  |> should.equal(Error(recording.CaptureFailed(recording.Interrupted)))
  let assert Error(missing) = cassette.load(destination, 10_000)
  missing.reason |> should.equal(error.FixtureMissing)
  let _ = http_gun.stop(recorded.client)
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
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  emit(server, <<"1\r\na\r\n":utf8>>)
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"a":utf8>>)))
  break_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  let _ = body.close(response.body)
  cassette.finish(recorded.recording)
  |> should.equal(
    Error(
      recording.CaptureFailed(recording.IoFailure(
        error.OpenFile,
        error.IsDirectory,
      )),
    ),
  )
  let assert Error(missing) = cassette.load(destination, 10_000)
  missing.reason |> should.equal(error.FixtureMissing)
  let _ = http_gun.stop(recorded.client)
}

pub fn stalled_writer_keeps_control_and_completed_http_test() {
  let #(port, server) = controlled()
  let destination = path()
  let c = local_config()
  let assert Ok(recorded) =
    cassette.record(
      config.Config(..c, deadline_ms: 300),
      destination,
      recording.default(),
    )
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  emit(server, <<"1\r\na\r\n":utf8>>)
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"a":utf8>>)))
  let fifo = stall_file(destination)
  emit(server, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  cassette.finish(recorded.recording) |> should.equal(Error(recording.Busy))
  let assert Ok(tail) = body.collect(response.body, 100)
  tail.bytes |> should.equal(<<"b":utf8>>)
  cassette.finish(recorded.recording)
  |> should.equal(Error(recording.CaptureFailed(recording.Interrupted)))
  release_fifo(fifo)
  let _ = body.close(response.body)
  let _ = http_gun.stop(recorded.client)
}

pub fn explicit_replacement_and_finalized_refusal_test() {
  let port = server()
  let destination = store("old")
  let options = recording.default()
  let assert Ok(recorded) =
    cassette.record(
      local_config(),
      destination,
      recording.Options(..options, replacement: recording.ReplaceExisting),
    )
  let assert Ok(_) = http_gun.send(recorded.client, req(port))
  cassette.finish(recorded.recording) |> should.equal(Ok(destination))
  cassette.load(destination, 10_000) |> should.be_ok
  let assert Error(failure) = http_gun.send(recorded.client, req(port))
  failure.evidence |> should.equal(error.NotSubmitted)
  let _ = http_gun.stop(recorded.client)
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
    cassette.record(local_config(), destination, recording.default())
  let reply = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(reply, http_gun.open(recorded.client, req(port)))
    })
  await_request(server)
  let _ = http_gun.stop(recorded.client)
  let assert Ok(Error(live)) = process.receive(reply, 1000)
  live.reason |> should.equal(error.Closed)
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Ok(destination))
  let assert Ok(value) = cassette.load(destination, 10_000)
  let assert Ok(client) = cassette.playback(value, local_config())
  let assert Error(replayed) = http_gun.open(client, req(port))
  replayed |> should.equal(live)
  let _ = http_gun.stop(client)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

pub fn concurrent_recording_and_replay_test() {
  let port = persistent()
  let destination = path()
  let requests = list.repeat(req(port), 30)
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(live) = http_gun.batch(recorded.client, requests, 10)
  list.all(live, result.is_ok) |> should.be_true
  cassette.finish(recorded.recording) |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(value) = cassette.load(destination, 100_000)
  let assert Ok(client) = cassette.playback(value, local_config())
  let assert Ok(replayed) = http_gun.batch(client, requests, 10)
  list.all(replayed, result.is_ok) |> should.be_true
  let _ = http_gun.stop(client)
  remove(destination)
}

@external(erlang, "http_gun_test_server", "disconnect")
fn disconnect(server: process.Pid) -> Nil

pub fn recorded_failure_retains_observed_prefix_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(reply) = http_gun.open(recorded.client, req(port))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next(reply.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  disconnect(server)
  let assert Error(failure) = body.next(reply.body, 1000)
  failure.evidence |> should.equal(error.MayHaveBeenSent)
  let _ = body.close(reply.body)
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = cassette.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next(replay.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  body.next(replay.body, 1000) |> should.equal(Error(failure))
  let _ = body.close(replay.body)
  let _ = http_gun.stop(client)
  remove(destination)
}

// DESIGN E1: timeout seals capture but neither drains nor cancels HTTP.
pub fn finish_wait_timeout_then_cancel_and_publish_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  recording.finish_wait(recorded.recording, 0)
  |> should.equal(Error(recording.WaitTimeout))
  let assert Error(refused) = http_gun.send(recorded.client, req(port))
  refused.evidence |> should.equal(error.NotSubmitted)
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  let _ = body.close(response.body)
  closed(server) |> should.be_true
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Ok(destination))
  recording.finish_wait(recorded.recording, 0) |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 10_000)
  let assert Ok(client) = cassette.playback(tape, local_config())
  let assert Ok(replay) = http_gun.open(client, req(port))
  body.next(replay.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  let assert Error(failure) = body.next(replay.body, 1000)
  failure.reason |> should.equal(error.Closed)
  let _ = body.close(replay.body)
  let _ = http_gun.stop(client)
  remove(destination)
}

pub fn finish_wait_contention_death_and_abort_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(response) = http_gun.open(recorded.client, req(port))
  let waiter =
    process.spawn_unlinked(fn() {
      let _ = wait_until_registered(recorded.recording)
      Nil
    })
  wait_for_finish_result(recorded.recording, recording.Busy, 1000)
  |> should.be_true
  process.kill(waiter)
  wait_for_finish_result(recorded.recording, recording.WaitTimeout, 1000)
  |> should.be_true
  recording.abort(recorded.recording) |> should.equal(Ok(Nil))
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Error(recording.CaptureFailed(recording.Interrupted)))
  let _ = body.close(response.body)
  closed(server) |> should.be_true
  let _ = http_gun.stop(recorded.client)
  let assert Error(missing) = cassette.load(destination, 10_000)
  missing.reason |> should.equal(error.FixtureMissing)
}

fn wait_for_finish_result(
  rec: recording.Recording,
  expected: recording.FinishError,
  tries: Int,
) -> Bool {
  case recording.finish_wait(rec, 0), tries {
    Error(actual), _ if actual == expected -> True
    _, 0 -> False
    _, _ -> wait_for_finish_result(rec, expected, tries - 1)
  }
}

fn wait_until_registered(
  rec: recording.Recording,
) -> Result(String, recording.FinishError) {
  case recording.finish_wait(rec, 10_000) {
    Error(recording.Busy) -> wait_until_registered(rec)
    result -> result
  }
}

pub fn token_cancellation_preserves_typed_outcome_on_replay_test() {
  let #(port, server) = controlled()
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(local_config(), destination, recording.default())
  let assert Ok(failure) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let assert Ok(response) =
        http_gun.open_with_options(recorded.client, req(port), options)
      emit(server, <<"3\r\nabc\r\n":utf8>>)
      body.next(response.body, 1000)
      |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
      cancellation.cancel(token)
      let assert Error(failure) = body.next(response.body, 1000)
      failure.reason |> should.equal(error.Cancelled)
      let _ = body.close(response.body)
      failure
    })
  closed(server) |> should.be_true
  recording.finish_wait(recorded.recording, 1000)
  |> should.equal(Ok(destination))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 100_000)
  let assert Ok(client) = cassette.playback(tape, local_config())
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  body.next(response.body, 1000) |> should.equal(Error(failure))
  let _ = body.close(response.body)
  let _ = http_gun.stop(client)
  remove(destination)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
