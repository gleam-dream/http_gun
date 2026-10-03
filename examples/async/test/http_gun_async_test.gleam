import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/option.{None}
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/testing
import http_gun_async/feed_job
import http_gun_async/workflow

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "http_gun_test_server", "await_request")
fn arrived(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

@external(erlang, "http_gun_test_server", "send_control")
fn send(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_h2_server", "controlled")
fn h2() -> Int

fn req(port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

fn budget() -> deadline.Deadline {
  deadline.after(5000)
}

// The reason and evidence of a job's HTTP failure.
fn http_failure(
  outcome: Result(feed_job.Completion, feed_job.Problem),
) -> #(error.Reason, error.Evidence) {
  let assert Error(feed_job.Http(failure)) = outcome
  #(error.reason(failure), error.evidence(failure))
}

fn failure_of(
  outcome: Result(a, error.Failure),
) -> #(error.Reason, error.Evidence) {
  let assert Error(failure) = outcome
  #(error.reason(failure), error.evidence(failure))
}

fn keep(_: BitArray) -> Result(feed_job.Decision, Nil) {
  Ok(feed_job.Continue)
}

fn start(
  client: http_gun.Client,
  request: request.Request(BitArray),
) -> feed_job.Job {
  let assert Ok(job) = feed_job.start(client, request, budget(), keep)
  job
}

fn waiting(client: http_gun.Client, n: Int, until: deadline.Deadline) -> Nil {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.queued_requests == n {
    True -> Nil
    False -> {
      let assert True = deadline.remaining_ms(until) > 0
      waiting(client, n, until)
    }
  }
}

fn empty(client: http_gun.Client, until: deadline.Deadline) -> Nil {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.open_bodies == 0 && stats.queued_requests == 0 {
    True -> Nil
    False -> {
      let assert True = deadline.remaining_ms(until) > 0
      empty(client, until)
    }
  }
}

fn one_slot() -> config.Config {
  local_config() |> config.with_max_open_bodies(1)
}

fn headers_and_body_cancellation() -> Nil {
  let assert Ok(client) = http_gun.start(local_config())
  let #(port, peer) = gated()
  let job = start(client, req(port))
  arrived(peer)
  // The server has received the request; the caller still has no response head.
  let assert Error(feed_job.WaitExpired) = feed_job.await(job, 0)
  feed_job.cancel(job)
  feed_job.cancel(job)
  let outcome = feed_job.await(job, 1000)
  let assert #(error.Cancelled, error.MaybeSent) = http_failure(outcome)
  let assert Error(feed_job.Http(failure)) = outcome
  let assert error.CancelledLocally = error.kind(failure)
  let assert False = error.is_retryable(failure, idempotent: True)
  let assert "the request was cancelled here" =
    workflow.advice(workflow.Http(failure))
  let assert True = closed(peer)
  let #(port, peer) = controlled()
  let job = start(client, req(port))
  arrived(peer)
  feed_job.cancel(job)
  let assert #(error.Cancelled, _) = http_failure(feed_job.await(job, 1000))
  let assert True = closed(peer)
  let assert Ok(_) = workflow.rest(client, req(persistent()))
  http_gun.stop(client)
}

fn admission_and_connect_cancellation() -> Nil {
  let assert Ok(client) = http_gun.start(one_slot())
  let #(port, peer) = controlled()
  let assert Ok(held) = http_gun.open(client, req(port))
  let job = start(client, req(port))
  waiting(client, 1, budget())
  feed_job.cancel(job)
  let assert #(error.Cancelled, error.NotSent) =
    http_failure(feed_job.await(job, 1000))
  body.close(held.body)
  let assert True = closed(peer)
  let #(port, peer) = gated()
  let job = start(client, req(port) |> request.set_scheme(http.Https))
  // The gated TCP peer has read a TLS ClientHello and withholds its handshake.
  arrived(peer)
  feed_job.cancel(job)
  let assert #(error.Cancelled, error.NotSent) =
    http_failure(feed_job.await(job, 1000))
  let assert Ok(stats) = http_gun.stats(client)
  let assert 0 = stats.connections
  http_gun.stop(client)
}

fn budgets_and_read_waits() -> Nil {
  let assert 0 = deadline.remaining_ms(deadline.after(0))
  let assert 0 = deadline.remaining_ms(deadline.after(-5))
  // A view's deadline replaces the client's request timeout, longer or
  // shorter: this client allows 100 ms, the view 5000 ms.
  let #(port, peer) = controlled()
  let assert Ok(client) =
    local_config()
    |> config.with_request_timeout(config.Milliseconds(100))
    |> http_gun.start
  let longer = deadline.after(5000)
  let assert Ok(reply) =
    http_gun.open(client |> http_gun.with_deadline(longer), req(port))
  // A local wait that passes leaves the stream intact.
  let assert Ok(None) = body.next_within(reply.body, 0)
  let assert Ok(None) = body.next_within(reply.body, 300)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Ok(body.Chunk(<<"x":utf8>>)) = body.next(reply.body)
  let assert True = deadline.remaining_ms(longer) > 3000
  io.println(
    "Deadline probe: client 100 ms, view 5000 ms, stream still open with "
    <> int.to_string(deadline.remaining_ms(longer))
    <> " ms left",
  )
  body.close(reply.body)
  let assert True = closed(peer)
  // Without the view, the client's 100 ms request timeout ends the read.
  let #(port, peer) = controlled()
  let assert Ok(reply) = http_gun.open(client, req(port))
  let assert Error(failure) = body.next(reply.body)
  let assert error.DeadlineExceeded = error.reason(failure)
  let assert error.TimedOut = error.kind(failure)
  // The request was sent: retrying is safe only for an idempotent request.
  let assert error.MaybeSent = error.evidence(failure)
  let assert True = error.is_retryable(failure, idempotent: True)
  let assert False = error.is_retryable(failure, idempotent: False)
  let assert True = closed(peer)
  body.close(reply.body)
  http_gun.stop(client)
  // A deadline that expires while the request is queued: never sent.
  let assert Ok(client) = http_gun.start(one_slot())
  let #(port, peer) = controlled()
  let assert Ok(held) = http_gun.open(client, req(port))
  let short = deadline.after(100)
  let assert Ok(job) = feed_job.start(client, req(port), short, keep)
  waiting(client, 1, budget())
  let assert #(error.DeadlineExceeded, error.NotSent) =
    http_failure(feed_job.await(job, 1000))
  let assert 0 = deadline.remaining_ms(short)
  let assert #(error.DeadlineExceeded, error.NotSent) =
    failure_of(http_gun.send(client |> http_gun.with_deadline(short), req(port)))
  body.close(held.body)
  let assert True = closed(peer)
  http_gun.stop(client)
}

fn early_error_and_exception() -> Nil {
  let assert Ok(client) = http_gun.start(local_config())
  let #(port, peer) = controlled()
  let assert Ok(job) =
    feed_job.start(client, req(port), budget(), fn(_) { Ok(feed_job.Stop) })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Ok(feed_job.Early(1)) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  let #(port, peer) = controlled()
  let assert Ok(job) =
    feed_job.start(client, req(port), budget(), fn(_) { Error(Nil) })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Error(feed_job.SinkFailed) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  let #(port, peer) = controlled()
  let assert Ok(job) =
    feed_job.start(client, req(port), budget(), fn(_) {
      panic as "controlled sink exception"
    })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Error(feed_job.WorkerStopped) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  empty(client, budget())
  http_gun.stop(client)
}

fn consumer_death_and_bounded_shutdown() -> Nil {
  let assert Ok(client) = http_gun.start(local_config())
  let #(port, peer) = controlled()
  let ready = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let release = process.new_subject()
      let job = start(client, req(port))
      process.send(ready, #(job, release))
      let assert Ok(Nil) = process.receive(release, 2000)
    })
  let assert Ok(#(job, release)) = process.receive(ready, 1000)
  arrived(peer)
  let assert Error(feed_job.WrongCaller) = feed_job.await(job, 0)
  process.send(release, Nil)
  let assert True = closed(peer)
  empty(client, budget())
  let #(port, peer) = controlled()
  let inside = process.new_subject()
  let assert Ok(job) =
    feed_job.start(client, req(port), budget(), fn(_) {
      process.send(inside, Nil)
      let never = process.new_subject()
      let _ = process.receive(never, 5000)
      Ok(feed_job.Continue)
    })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Ok(Nil) = process.receive(inside, 1000)
  let assert Ok(Nil) = feed_job.shutdown(job, 10)
  let assert True = closed(peer)
  empty(client, budget())
  http_gun.stop(client)
}

fn copies_and_conflicts() -> Nil {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(reply) = http_gun.open(client, req(port))
  let copied = reply.body
  send(peer, <<"1\r\na\r\n":utf8>>)
  let assert Ok(body.Chunk(<<"a":utf8>>)) = body.next(reply.body)
  send(peer, <<"1\r\nb\r\n":utf8>>)
  let assert Ok(body.Chunk(<<"b":utf8>>)) = body.next(copied)
  let wrong = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(wrong, body.next_within(copied, 0))
    })
  let assert Ok(outcome) = process.receive(wrong, 1000)
  let assert #(error.WrongOwner, _) = failure_of(outcome)
  let clash = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      conflict(copied, budget())
      process.send(clash, Nil)
      body.close(copied)
    })
  let assert #(error.Closed, _) = failure_of(body.next(reply.body))
  let assert Ok(Nil) = process.receive(clash, 1000)
  // Closing is idempotent, from any holder of a copy.
  body.close(copied)
  body.close(reply.body)
  let assert True = closed(peer)
  http_gun.stop(client)
}

fn conflict(source: body.Body, until: deadline.Deadline) -> Nil {
  let assert Error(failure) = body.next_within(source, 0)
  case error.reason(failure) {
    error.ReadConflict -> Nil
    error.WrongOwner -> {
      let assert True = deadline.remaining_ms(until) > 0
      conflict(source, until)
    }
    _ -> panic as "unexpected conflicting-read outcome"
  }
}

fn supervised_restart() -> Nil {
  let name = process.new_name("http_gun_async_client")
  let assert Ok(supervisor) = feed_job.supervise(local_config(), name)
  // One handle for the application's lifetime, valid across restarts.
  let client = http_gun.named(name)
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  let assert Ok(first) = process.named(name)
  process.kill(first)
  let second = restarted(name, first, budget())
  let assert True = second != first
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  flow(client, req(persistent()))
  // While no client is registered, as during a restart, a call fails before
  // anything is sent, so it is always safe to retry.
  let absent = http_gun.named(process.new_name("http_gun_async_absent"))
  let assert Error(failure) = http_gun.send(absent, req(persistent()))
  let assert error.ClientClosed = error.reason(failure)
  let assert error.Unavailable = error.kind(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert True = error.is_retryable(failure, idempotent: False)
  process.unlink(supervisor.pid)
  process.kill(supervisor.pid)
}

fn restarted(
  name: process.Name(http_gun.Message),
  old: process.Pid,
  until: deadline.Deadline,
) -> process.Pid {
  case process.named(name) {
    Ok(pid) if pid != old -> pid
    _ -> {
      let assert True = deadline.remaining_ms(until) > 0
      process.sleep(1)
      restarted(name, old, until)
    }
  }
}

fn flow(client: http_gun.Client, request: request.Request(BitArray)) -> Nil {
  let job = start(client, request)
  let assert Ok(feed_job.Eof(3, [])) = feed_job.await(job, 1000)
  let assert Ok(job) =
    feed_job.start(client, request, budget(), fn(_) { Ok(feed_job.Stop) })
  let assert Ok(feed_job.Early(3)) = feed_job.await(job, 1000)
  Nil
}

fn modes() -> Nil {
  let request =
    req(persistent())
    |> request.set_header("accept", "application/octet-stream")
  let assert Ok(client) = http_gun.start(local_config())
  flow(client, request)
  let assert Ok(3) = workflow.download(client, request)
  let assert Ok(_) = workflow.rest_pair(client, request, request)
  http_gun.stop(client)
  let exchange =
    testing.exchange(
      request,
      testing.Respond(
        response.new(200) |> response.set_body([<<"abc":utf8>>]),
        testing.Finished([]),
      ),
    )
  let assert Ok(client) =
    testing.playback(testing.script([exchange, exchange]), local_config())
  let mismatched = request |> request.set_header("accept", "text/plain")
  let assert Error(failure) = http_gun.send(client, mismatched)
  let assert error.PlaybackMismatch(0) = error.reason(failure)
  let assert error.Playback = error.kind(failure)
  flow(client, request)
  let assert #(error.PlaybackExhausted, _) =
    failure_of(http_gun.send(client, request))
  http_gun.stop(client)
  let path = "build/probe-cassette.json"
  let assert Ok(recorded) =
    cassette.record(local_config(), path, replacing(1_000_000))
  flow(recorded.client, request)
  let assert Ok(_) = cassette.finish(recorded.recording, 1000)
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert #(error.PlaybackMismatch(0), _) =
    failure_of(http_gun.send(client, mismatched))
  flow(client, request)
  let assert Ok(stats) = http_gun.stats(client)
  let assert 0 = stats.connections
  http_gun.stop(client)
}

fn replacing(max_bytes: Int) -> cassette.RecordOptions {
  cassette.options()
  |> cassette.with_max_bytes(max_bytes)
  |> cassette.replace_existing
}

fn h2_jobs() -> Nil {
  let port = h2()
  let assert Ok(client) =
    local_config()
    |> config.with_protocol(config.RequireHttp2)
    |> config.with_trust(config.CustomCa("test/fixtures/ca.crt"))
    |> config.with_max_connections(1)
    |> config.with_max_connections_per_origin(1)
    |> http_gun.start
  let base = req(port) |> request.set_scheme(http.Https)
  let first = process.new_subject()
  let assert Ok(job) =
    feed_job.start(client, request.set_path(base, "/slow"), budget(), fn(bytes) {
      process.send(first, bytes)
      Ok(feed_job.Continue)
    })
  let assert Ok(<<"first":utf8>>) = process.receive(first, 1000)
  // H2 window-bound response cannot finish until this owner renews demand.
  let assert Ok(sibling) =
    http_gun.open(client, request.set_path(base, "/window-demand"))
  let assert config.H2 = body.protocol(sibling.body)
  feed_job.cancel(job)
  let assert #(error.Cancelled, _) = http_failure(feed_job.await(job, 1000))
  let assert Ok(collected) = body.collect(sibling.body, 20_000)
  let assert 16_387 = bit_array.byte_size(collected.bytes)
  body.close(sibling.body)
  let assert Ok(next) = http_gun.send(client, request.set_path(base, "/fast"))
  let assert config.H2 = next.protocol
  let assert Ok(stats) = http_gun.stats(client)
  let assert 1 = stats.connections
  http_gun.stop(client)
}

fn slow_sink_and_shutdown() -> Nil {
  let assert Ok(client) = http_gun.start(local_config())
  let #(port, peer) = controlled()
  let seen = process.new_subject()
  let assert Ok(job) =
    feed_job.start(client, req(port), budget(), fn(bytes) {
      let ack = process.new_subject()
      process.send(seen, #(bytes, ack))
      let assert Ok(Nil) = process.receive(ack, 1000)
      Ok(feed_job.Continue)
    })
  arrived(peer)
  send(peer, <<"1\r\na\r\n":utf8>>)
  let assert Ok(#(<<"a":utf8>>, ack)) = process.receive(seen, 1000)
  send(peer, <<"1\r\nb\r\n0\r\n\r\n":utf8>>)
  let assert Error(Nil) = process.receive(seen, 0)
  process.send(ack, Nil)
  let assert Ok(#(<<"b":utf8>>, ack)) = process.receive(seen, 1000)
  process.send(ack, Nil)
  let assert Ok(feed_job.Eof(2, [])) = feed_job.await(job, 1000)
  http_gun.stop(client)
  let assert True = closed(peer)
  // `stop` lets an open body finish within the shutdown timeout, then
  // cancels it; this stream never ends, so the job sees the cancellation.
  let assert Ok(client) =
    local_config() |> config.with_shutdown_timeout(100) |> http_gun.start
  let #(port, peer) = controlled()
  let job = start(client, req(port))
  arrived(peer)
  http_gun.stop(client)
  let assert Error(feed_job.Http(_)) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  Nil
}

fn recording_prefix_and_failure() -> Nil {
  let #(port, peer) = controlled()
  let request = req(port)
  let path = "build/early-prefix.json"
  let assert Ok(recorded) =
    cassette.record(local_config(), path, replacing(1_000_000))
  let assert Ok(job) =
    feed_job.start(recorded.client, request, budget(), fn(_) {
      Ok(feed_job.Stop)
    })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Ok(feed_job.Early(1)) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  let assert Ok(_) = cassette.finish(recorded.recording, 1000)
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(client) = testing.playback(tape, local_config())
  let assert Ok(job) =
    feed_job.start(client, request, budget(), fn(_) { Ok(feed_job.Stop) })
  let assert Ok(feed_job.Early(1)) = feed_job.await(job, 1000)
  http_gun.stop(client)
  // A capture failure is separate from the HTTP outcome: the request
  // succeeds, the recording fails and publishes nothing.
  let path = "build/capture-limit.json"
  let assert Ok(recorded) = cassette.record(local_config(), path, replacing(1))
  let job = start(recorded.client, req(persistent()))
  let assert Ok(feed_job.Eof(3, [])) = feed_job.await(job, 1000)
  let assert Error(cassette.CaptureFailed(cassette.CaptureLimit)) =
    cassette.finish(recorded.recording, 1000)
  let assert Error(cassette.Missing) = cassette.load(path, 1000)
  http_gun.stop(recorded.client)
}

pub fn main() -> Nil {
  headers_and_body_cancellation()
  io.println("PASS head gap, header/body cancellation, shared-client reuse")
  admission_and_connect_cancellation()
  io.println("PASS admission and TLS-connection cancellation")
  budgets_and_read_waits()
  io.println(
    "PASS view deadline over client timeout, local read wait, queued expiry",
  )
  early_error_and_exception()
  io.println("PASS early stop, sink error, exception cleanup")
  consumer_death_and_bounded_shutdown()
  io.println("PASS consumer death, copied job, bounded worker shutdown")
  copies_and_conflicts()
  io.println(
    "PASS shared body cursor, wrong owner, conflicting read, idempotent close",
  )
  supervised_restart()
  io.println(
    "PASS supervised restart behind one named handle, absent client NotSent",
  )
  modes()
  io.println(
    "PASS same async consumer live/script/record/replay, strict matching, download and shared-budget workflows",
  )
  h2_jobs()
  io.println(
    "PASS verified H2, one connection, cancelled job and unfinished healthy sibling",
  )
  slow_sink_and_shutdown()
  io.println("PASS synchronous sink backpressure and shared-client shutdown")
  recording_prefix_and_failure()
  io.println(
    "PASS live prefix recording/offline replay and independent capture failure",
  )
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
