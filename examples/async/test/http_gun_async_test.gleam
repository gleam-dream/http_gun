import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/option.{Some}
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/fixture
import http_gun/recording
import http_gun/request_options
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
  let assert Ok(value) = deadline.after(5000)
  value
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
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.waiting == n {
    True -> Nil
    False -> {
      let assert True = deadline.remaining_ms(until) > 0
      waiting(client, n, until)
    }
  }
}

fn empty(client: http_gun.Client, until: deadline.Deadline) -> Nil {
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.bodies == 0 && stats.waiting == 0 {
    True -> Nil
    False -> {
      let assert True = deadline.remaining_ms(until) > 0
      empty(client, until)
    }
  }
}

fn one_slot() -> config.Config {
  let c = config.default()
  config.Config(..c, limits: config.Limits(..c.limits, active: 1))
}

fn headers_and_body_cancellation() -> Nil {
  let assert Ok(client) = http_gun.start(config.default())
  let #(port, peer) = gated()
  let job = start(client, req(port))
  arrived(peer)
  // The server has received the request; the caller still has no response head.
  let assert Error(feed_job.WaitExpired) = feed_job.await(job, 0)
  feed_job.cancel(job)
  feed_job.cancel(job)
  let assert Error(feed_job.Http(error.Failure(
    error.Cancelled,
    error.MayHaveBeenSent,
  ))) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  let #(port, peer) = controlled()
  let job = start(client, req(port))
  arrived(peer)
  feed_job.cancel(job)
  let assert Error(feed_job.Http(error.Failure(error.Cancelled, _))) =
    feed_job.await(job, 1000)
  let assert True = closed(peer)
  let assert Ok(_) = workflow.rest(client, req(persistent()))
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn admission_and_connect_cancellation() -> Nil {
  let assert Ok(client) = http_gun.start(one_slot())
  let #(port, peer) = controlled()
  let assert Ok(held) = http_gun.open(client, req(port))
  let job = start(client, req(port))
  waiting(client, 1, budget())
  feed_job.cancel(job)
  let assert Error(feed_job.Http(error.Failure(
    error.Cancelled,
    error.NotSubmitted,
  ))) = feed_job.await(job, 1000)
  let assert Ok(Nil) = body.close(held.body)
  let assert True = closed(peer)
  let #(port, peer) = gated()
  let job = start(client, req(port) |> request.set_scheme(http.Https))
  // The gated TCP peer has read a TLS ClientHello and withholds its handshake.
  arrived(peer)
  feed_job.cancel(job)
  let assert Error(feed_job.Http(error.Failure(
    error.Cancelled,
    error.NotSubmitted,
  ))) = feed_job.await(job, 1000)
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 0 = stats.connections
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn budgets_and_read_waits() -> Nil {
  let assert Ok(downloads) = workflow.start_downloads()
  let assert 300_000 = http_gun.request_ceiling_ms(downloads)
  let assert Ok(expired) = deadline.after(0)
  let assert 0 = workflow.estimate(downloads, expired)
  let _ = http_gun.stop(downloads)
  let #(port, peer) = controlled()
  let assert Ok(client) =
    http_gun.start(config.Config(..config.default(), deadline_ms: 100))
  let assert Ok(longer) = deadline.after(5000)
  let assert Ok(reply) =
    http_gun.open_with_options(
      client,
      req(port),
      request_options.Options(
        ..request_options.default(),
        deadline: Some(longer),
      ),
    )
  let assert Error(error.Failure(error.ReadTimeout, _)) =
    body.next(reply.body, 0)
  let assert Error(error.Failure(error.DeadlineExceeded, _)) =
    body.next(reply.body, 1000)
  let assert True = deadline.remaining_ms(longer) > 3000
  io.println(
    "Ceiling probe: supplied 5000 ms, client 100 ms, supplied budget still has "
    <> int.to_string(deadline.remaining_ms(longer))
    <> " ms",
  )
  let assert True = closed(peer)
  let _ = body.close(reply.body)
  let _ = http_gun.stop(client)
  let assert Ok(client) = http_gun.start(one_slot())
  let #(port, peer) = controlled()
  let assert Ok(held) = http_gun.open(client, req(port))
  let assert Ok(short) = deadline.after(100)
  let assert Ok(job) = feed_job.start(client, req(port), short, keep)
  waiting(client, 1, budget())
  let assert Error(feed_job.Http(error.Failure(
    error.DeadlineExceeded,
    error.NotSubmitted,
  ))) = feed_job.await(job, 1000)
  let assert 0 = deadline.remaining_ms(short)
  let assert Error(error.Failure(error.DeadlineExceeded, error.NotSubmitted)) =
    http_gun.send_with_options(
      client,
      req(port),
      request_options.Options(
        ..request_options.default(),
        deadline: Some(short),
      ),
    )
  let _ = body.close(held.body)
  let assert True = closed(peer)
  let _ = http_gun.stop(client)
  Nil
}

fn early_error_and_exception() -> Nil {
  let assert Ok(client) = http_gun.start(config.default())
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
  let _ = http_gun.stop(client)
  Nil
}

fn consumer_death_and_bounded_shutdown() -> Nil {
  let assert Ok(client) = http_gun.start(config.default())
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
  let _ = http_gun.stop(client)
  Nil
}

fn copies_and_conflicts() -> Nil {
  let #(port, peer) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(reply) = http_gun.open(client, req(port))
  let copied = reply.body
  send(peer, <<"1\r\na\r\n":utf8>>)
  let assert Ok(body.Chunk(<<"a":utf8>>)) = body.next(reply.body, 1000)
  send(peer, <<"1\r\nb\r\n":utf8>>)
  let assert Ok(body.Chunk(<<"b":utf8>>)) = body.next(copied, 1000)
  let wrong = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() { process.send(wrong, body.next(copied, 0)) })
  let assert Ok(Error(error.Failure(error.WrongOwner, _))) =
    process.receive(wrong, 1000)
  let clash = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      conflict(copied, budget())
      process.send(clash, Nil)
      let _ = body.close(copied)
    })
  let assert Error(error.Failure(error.Closed, _)) = body.next(reply.body, 1000)
  let assert Ok(Nil) = process.receive(clash, 1000)
  let assert Ok(Nil) = body.close(copied)
  let assert Ok(Nil) = body.close(reply.body)
  let assert True = closed(peer)
  let _ = http_gun.stop(client)
  Nil
}

fn conflict(source: body.Body, until: deadline.Deadline) -> Nil {
  case body.next(source, 0) {
    Error(error.Failure(error.ReadConflict, _)) -> Nil
    Error(error.Failure(error.WrongOwner, _)) -> {
      let assert True = deadline.remaining_ms(until) > 0
      conflict(source, until)
    }
    _ -> panic as "unexpected conflicting-read outcome"
  }
}

fn supervised_restart() -> Nil {
  let ready = process.new_subject()
  let assert Ok(supervisor) = feed_job.supervise(config.default(), ready)
  let assert Ok(first) = process.receive(ready, 1000)
  let assert Ok(_) = http_gun.send(first, req(persistent()))
  let assert Ok(Nil) = http_gun.stop(first)
  let assert Ok(second) = process.receive(ready, 1000)
  let assert 30_000 = http_gun.request_ceiling_ms(first)
  let assert 30_000 = http_gun.request_ceiling_ms(second)
  let assert Error(error.Failure(error.ClientClosed, _)) =
    http_gun.send(first, req(persistent()))
  let assert Ok(_) = http_gun.send(second, req(persistent()))
  process.unlink(supervisor.pid)
  process.kill(supervisor.pid)
}

fn flow(client: http_gun.Client, request: request.Request(BitArray)) -> Nil {
  let assert 30_000 = http_gun.request_ceiling_ms(client)
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
  let assert Ok(client) = http_gun.start(config.default())
  flow(client, request)
  let assert Ok(3) = workflow.download(client, request)
  let assert Ok(_) = workflow.rest_pair(client, request, request)
  let _ = http_gun.stop(client)
  let exchange =
    fixture.Exchange(
      request,
      fixture.Respond(
        response.new(200) |> response.set_body([<<"abc":utf8>>]),
        fixture.Complete([]),
      ),
    )
  let assert Ok(client) = testing.start(config.default(), [exchange, exchange])
  let assert Error(error.Failure(error.FixtureMismatch(0), _)) =
    http_gun.send(client, request |> request.set_header("accept", "text/plain"))
  flow(client, request)
  let assert Error(error.Failure(error.FixtureExhausted, _)) =
    http_gun.send(client, request)
  let _ = http_gun.stop(client)
  let path = "build/probe-cassette.json"
  let assert Ok(recorded) =
    cassette.record(
      config.default(),
      path,
      recording.Options(1_000_000, recording.ReplaceExisting),
    )
  flow(recorded.client, request)
  let assert Ok(_) = recording.finish_wait(recorded.recording, 1000)
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, config.default())
  let assert Error(error.Failure(error.FixtureMismatch(0), _)) =
    http_gun.send(client, request |> request.set_header("accept", "text/plain"))
  flow(client, request)
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 0 = stats.connections
  let _ = http_gun.stop(client)
  Nil
}

fn h2_jobs() -> Nil {
  let port = h2()
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        protocol: config.RequireHttp2,
        trust: config.CustomCa("test/fixtures/ca.crt"),
        limits: config.Limits(..c.limits, connections: 1, per_origin: 1),
      ),
    )
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
  let assert Error(feed_job.Http(error.Failure(error.Cancelled, _))) =
    feed_job.await(job, 1000)
  let assert Ok(collected) = body.collect(sibling.body, 20_000)
  let assert 16_387 = bit_array.byte_size(collected.bytes)
  let _ = body.close(sibling.body)
  let assert Ok(next) = http_gun.send(client, request.set_path(base, "/fast"))
  let assert config.H2 = next.protocol
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 1 = stats.connections
  let _ = http_gun.stop(client)
  Nil
}

fn slow_sink_and_shutdown() -> Nil {
  let assert Ok(client) = http_gun.start(config.default())
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
  let _ = http_gun.stop(client)
  let assert True = closed(peer)
  let assert Ok(client) = http_gun.start(config.default())
  let #(port, peer) = controlled()
  let job = start(client, req(port))
  arrived(peer)
  let assert Ok(Nil) = http_gun.stop(client)
  let assert Error(feed_job.Http(_)) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  Nil
}

fn recording_prefix_and_failure() -> Nil {
  let #(port, peer) = controlled()
  let request = req(port)
  let path = "build/early-prefix.json"
  let assert Ok(recorded) =
    cassette.record(
      config.default(),
      path,
      recording.Options(1_000_000, recording.ReplaceExisting),
    )
  let assert Ok(job) =
    feed_job.start(recorded.client, request, budget(), fn(_) {
      Ok(feed_job.Stop)
    })
  arrived(peer)
  send(peer, <<"1\r\nx\r\n":utf8>>)
  let assert Ok(feed_job.Early(1)) = feed_job.await(job, 1000)
  let assert True = closed(peer)
  let assert Ok(_) = recording.finish_wait(recorded.recording, 1000)
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(client) = cassette.playback(tape, config.default())
  let assert Ok(job) =
    feed_job.start(client, request, budget(), fn(_) { Ok(feed_job.Stop) })
  let assert Ok(feed_job.Early(1)) = feed_job.await(job, 1000)
  let _ = http_gun.stop(client)
  let path = "build/capture-limit.json"
  let assert Ok(recorded) =
    cassette.record(
      config.default(),
      path,
      recording.Options(1, recording.ReplaceExisting),
    )
  let job = start(recorded.client, req(persistent()))
  let assert Ok(feed_job.Eof(3, [])) = feed_job.await(job, 1000)
  let assert Error(recording.CaptureFailed(recording.CaptureLimit)) =
    recording.finish_wait(recorded.recording, 1000)
  let assert Error(error.Failure(error.FixtureMissing, _)) =
    cassette.load(path, 1000)
  let _ = http_gun.stop(recorded.client)
  Nil
}

pub fn main() -> Nil {
  headers_and_body_cancellation()
  io.println("PASS head gap, header/body cancellation, shared-client reuse")
  admission_and_connect_cancellation()
  io.println("PASS admission and TLS-connection cancellation")
  budgets_and_read_waits()
  io.println("PASS ceiling, queued expiry, expired budget, read wait")
  early_error_and_exception()
  io.println("PASS early stop, sink error, exception cleanup")
  consumer_death_and_bounded_shutdown()
  io.println("PASS consumer death, copied job, bounded worker shutdown")
  copies_and_conflicts()
  io.println(
    "PASS shared body cursor, wrong owner, conflicting read, idempotent close",
  )
  supervised_restart()
  io.println("PASS supervision restart, new capability, stale capability")
  modes()
  io.println(
    "PASS same async consumer live/script/record/replay, strict matching, two fallible-scope use cases",
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
