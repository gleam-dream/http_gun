import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/fixture
import http_gun/recording
import http_gun/request_options
import http_gun/telemetry
import http_gun/testing
import sinal
import sinal/forwarder

pub fn scripted_lifecycle_has_correlation_without_network_submission_test() {
  let assert Ok(fwd) =
    forwarder.new(process.new_name("http-gun-observations"), 32)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let events = process.new_subject()
  let assert Ok(id) = sinal.handler_id("http-gun-script-observation")
  let assert Ok(attachment) =
    sinal.observe(id, telemetry.event(), fn(time, metadata) {
      process.send(events, #(time, metadata))
    })
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.Response(201, [], [<<0, 255>>]),
        fixture.Complete([]),
      ),
    )
  let settings = config.Config(..local_config(), observations: Some(fwd))
  let assert Ok(shared) = testing.start(settings, [exchange])
  let correlation = telemetry.new_id()
  let client = http_gun.with_correlation(shared, correlation)
  let assert Ok(result) = http_gun.send(client, req)
  result.response |> should.equal(response.Response(201, [], <<0, 255>>))
  let seen = receive_events(events, 4)
  let expected = [
    telemetry.AdmissionEntered,
    telemetry.AdmissionGranted,
    telemetry.ResponseHeaders(201),
    telemetry.HttpTerminated(telemetry.Complete),
  ]
  let stages = list.map(seen, fn(event) { event.1.milestone })
  list.each(expected, fn(stage) {
    list.contains(stages, stage) |> should.be_true
  })
  // Pool and body producers can interleave at delivery. Source timestamps
  // describe the milestones without promising cross-process arrival order.
  let times =
    list.map(expected, fn(stage) {
      let assert Ok(event) =
        list.find(seen, fn(event) { event.1.milestone == stage })
      event.0.monotonic_ms
    })
  let assert [entered, granted, headers, terminated] = times
  { entered <= granted && granted <= headers && headers <= terminated }
  |> should.be_true
  let assert [first, ..] = seen
  list.each(seen, fn(event) {
    event.1.request_id |> should.equal(first.1.request_id)
    event.1.correlation |> should.equal(Some(correlation))
    event.1.mode |> should.equal(telemetry.Offline)
  })
  let _ = http_gun.stop(shared)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
}

fn receive_events(
  subject: process.Subject(#(telemetry.Timing, telemetry.Metadata)),
  remaining: Int,
) -> List(#(telemetry.Timing, telemetry.Metadata)) {
  case remaining {
    0 -> []
    _ -> {
      let assert Ok(event) = process.receive(subject, 1000)
      [event, ..receive_events(subject, remaining - 1)]
    }
  }
}

@external(erlang, "http_gun_measure_ffi", "queue_len")
fn queue_len(pid: process.Pid) -> Int

pub fn blocked_observer_drops_without_stalling_bounded_batch_test() {
  let assert Ok(fwd) =
    forwarder.new(process.new_name("http-gun-blocked-observer"), 1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let entered = process.new_subject()
  let finished = process.new_subject()
  let drops = process.new_subject()
  let assert Ok(id) = sinal.handler_id("http-gun-blocked-observer")
  let assert Ok(attachment) =
    sinal.observe(id, telemetry.event(), fn(_, _) {
      let release = process.new_subject()
      process.send(entered, release)
      process.receive_forever(release)
    })
  let assert Ok(drop_id) = sinal.handler_id("http-gun-drops")
  let assert Ok(drop_attachment) =
    sinal.observe(drop_id, forwarder.dropped_event(), fn(value, _) {
      process.send(drops, value)
    })
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(response.Response(204, [], []), fixture.Complete([])),
    )
  let requests = list.repeat(req, 1000)
  let settings = config.Config(..local_config(), observations: Some(fwd))
  let assert Ok(client) = testing.start(settings, list.repeat(exchange, 1000))
  let _ =
    process.spawn_unlinked(fn() {
      process.send(finished, http_gun.batch(client, requests, 16))
    })
  let assert Ok(release) = process.receive(entered, 1000)
  // Completion is required before releasing the handler: synchronous delivery
  // or observation backpressure would fail this receive.
  let assert Ok(Ok(results)) = process.receive(finished, 5000)
  list.length(results) |> should.equal(1000)
  list.each(results, fn(result) { result |> should.be_ok })
  // Capacity includes the executing handler. Only its coalesced drop notice
  // remains in the forwarder mailbox, regardless of request count.
  queue_len(started.pid) |> should.equal(1)
  process.send(release, Nil)
  let assert Ok(dropped) = process.receive(drops, 1000)
  { dropped.rejected >= 3999 } |> should.be_true
  let _ = http_gun.stop(client)
  let assert Ok(Nil) = sinal.detach(attachment)
  let assert Ok(Nil) = sinal.detach(drop_attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
}

type Observer {
  Observer(
    target: forwarder.Forwarder,
    pid: process.Pid,
    attachment: sinal.Attachment,
    events: process.Subject(#(telemetry.Timing, telemetry.Metadata)),
  )
}

fn observer(name: String) -> Observer {
  let assert Ok(target) = forwarder.new(process.new_name(name), 64)
  let spec = forwarder.supervised(target)
  let assert Ok(started) = spec.start()
  let events = process.new_subject()
  let assert Ok(id) = sinal.handler_id(name)
  let assert Ok(attachment) =
    sinal.observe(id, telemetry.event(), fn(time, metadata) {
      process.send(events, #(time, metadata))
    })
  Observer(target, started.pid, attachment, events)
}

fn stop_observer(observer: Observer) -> Nil {
  let assert Ok(Nil) = sinal.detach(observer.attachment)
  process.unlink(observer.pid)
  process.kill(observer.pid)
}

fn until(
  observer: Observer,
  stage: telemetry.Milestone,
  remaining: Int,
) -> List(#(telemetry.Timing, telemetry.Metadata)) {
  let assert True = remaining > 0
  let assert Ok(event) = process.receive(observer.events, 2000)
  case event.1.milestone == stage {
    True -> [event]
    False -> [event, ..until(observer, stage, remaining - 1)]
  }
}

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

pub fn gun_return_is_observed_before_headers_and_local_cancellation_test() {
  let observer = observer("http-gun-submission-observer")
  let settings =
    config.Config(..local_config(), observations: Some(observer.target))
  let assert Ok(client) = http_gun.start(settings)
  let #(port, server) = gated()
  let result = process.new_subject()
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let _ =
        process.spawn_unlinked(fn() {
          let options =
            request_options.Options(
              ..request_options.default(),
              cancellation: Some(token),
            )
          process.send(
            result,
            http_gun.send_with_options(client, local_request(port), options),
          )
        })
      await_request(server)
      let first = until(observer, telemetry.GunCallReturned, 8)
      list.any(first, fn(value) {
        value.1.milestone == telemetry.AdmissionGranted
      })
      |> should.be_true
      list.all(first, fn(value) { value.1.mode == telemetry.Live })
      |> should.be_true
      cancellation.cancel(token)
      let assert Ok(Error(failure)) = process.receive(result, 1000)
      failure.reason |> should.equal(error.Cancelled)
      let final =
        until(observer, telemetry.HttpTerminated(telemetry.LocallyCancelled), 8)
      list.any(list.append(first, final), fn(value) {
        case value.1.milestone {
          telemetry.ResponseHeaders(_) -> True
          _ -> False
        }
      })
      |> should.be_false
    })
  let _ = http_gun.stop(client)
  stop_observer(observer)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

pub fn queued_deadline_terminates_without_grant_or_gun_return_test() {
  let observer = observer("http-gun-queue-observer")
  let defaults = local_config()
  let settings =
    config.Config(
      ..defaults,
      observations: Some(observer.target),
      limits: config.Limits(..defaults.limits, connections: 1, per_origin: 1),
    )
  let assert Ok(shared) = http_gun.start(settings)
  let #(port, _) = controlled()
  let assert Ok(first) = http_gun.open(shared, local_request(port))
  let _ = until(observer, telemetry.ResponseHeaders(200), 8)
  let result = process.new_subject()
  let correlation = telemetry.new_id()
  let client = http_gun.with_correlation(shared, correlation)
  let assert Ok(budget) = deadline.after(1000)
  let _ =
    process.spawn_unlinked(fn() {
      let options =
        request_options.Options(
          ..request_options.default(),
          deadline: Some(budget),
        )
      process.send(
        result,
        http_gun.send_with_options(client, local_request(port), options),
      )
    })
  let waiting = until(observer, telemetry.AdmissionWaiting, 8)
  let assert Ok(Error(failure)) = process.receive(result, 2000)
  failure
  |> should.equal(error.Failure(error.DeadlineExceeded, error.NotSubmitted))
  let terminal =
    until(observer, telemetry.HttpTerminated(telemetry.DeadlineExpired), 8)
  let seen = list.append(waiting, terminal)
  list.all(seen, fn(value) { value.1.correlation == Some(correlation) })
  |> should.be_true
  list.any(seen, fn(value) {
    value.1.milestone == telemetry.AdmissionGranted
    || value.1.milestone == telemetry.GunCallReturned
  })
  |> should.be_false
  let _ = body.close(first.body)
  let _ = http_gun.stop(shared)
  stop_observer(observer)
}

@external(erlang, "http_gun_test_server", "start")
fn server() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

pub fn recording_and_strict_playback_keep_telemetry_out_of_matching_test() {
  let observer = observer("http-gun-cassette-observer")
  let settings =
    config.Config(..local_config(), observations: Some(observer.target))
  let req = local_request(server())
  let path = temp_path()
  let assert Ok(recorded) = cassette.record(settings, path, recording.default())
  let tag = telemetry.new_id()
  let assert Ok(original) =
    http_gun.send(http_gun.with_correlation(recorded.client, tag), req)
  let live = until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.all(live, fn(value) { value.1.mode == telemetry.Recorded })
  |> should.be_true
  list.any(live, fn(value) { value.1.milestone == telemetry.GunCallReturned })
  |> should.be_true
  let assert Ok(_) = recording.finish_wait(recorded.recording, 1000)
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 100_000)
  let assert Ok(playback) = cassette.playback(tape, settings)
  let assert Error(mismatch) =
    http_gun.send(playback, request.set_path(req, "/different"))
  mismatch.reason |> should.equal(error.FixtureMismatch(0))
  let rejected = until(observer, telemetry.HttpTerminated(telemetry.Failed), 8)
  list.any(rejected, fn(value) {
    value.1.milestone == telemetry.AdmissionGranted
  })
  |> should.be_false
  // Different correlation, same exact request: mismatch did not consume it.
  let assert Ok(replayed) =
    http_gun.send(http_gun.with_correlation(playback, telemetry.new_id()), req)
  replayed.response |> should.equal(original.response)
  let offline = until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.all(offline, fn(value) { value.1.mode == telemetry.Offline })
  |> should.be_true
  list.any(offline, fn(value) { value.1.milestone == telemetry.GunCallReturned })
  |> should.be_false
  let _ = http_gun.stop(playback)
  remove_fixture(path)
  // A capture failure does not become an HTTP failure observation.
  let failed_path = temp_path()
  let assert Ok(limited) =
    cassette.record(
      settings,
      failed_path,
      recording.Options(1, recording.RefuseExisting),
    )
  let assert Ok(_) = http_gun.send(limited.client, local_request(server()))
  let captured =
    until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.any(captured, fn(value) {
    value.1.milestone == telemetry.HttpTerminated(telemetry.Failed)
  })
  |> should.be_false
  recording.finish_wait(limited.recording, 1000)
  |> should.equal(Error(recording.CaptureFailed(recording.CaptureLimit)))
  let _ = http_gun.stop(limited.client)
  stop_observer(observer)
}

pub fn unavailable_dead_and_throwing_observers_preserve_http_test() {
  let assert Ok(target) =
    forwarder.new(process.new_name("http-gun-fault-observer"), 16)
  let settings = config.Config(..local_config(), observations: Some(target))
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(response.Response(204, [], []), fixture.Complete([])),
    )
  let assert Ok(client) = testing.start(settings, list.repeat(exchange, 3))
  http_gun.send(client, req) |> should.be_ok
  let spec = forwarder.supervised(target)
  let assert Ok(started) = spec.start()
  let entered = process.new_subject()
  let assert Ok(id) = sinal.handler_id("http-gun-throwing-observer")
  let assert Ok(_) =
    sinal.observe(id, telemetry.event(), fn(_, _) {
      process.send(entered, process.self())
      panic as "test observer failed"
    })
  http_gun.send(client, req) |> should.be_ok
  let assert Ok(handler_pid) = process.receive(entered, 1000)
  handler_pid |> should.equal(started.pid)
  let monitor = process.monitor(started.pid)
  process.unlink(started.pid)
  process.kill(started.pid)
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(down) { down })
  let assert Ok(_) = process.selector_receive(selector, 1000)
  http_gun.send(client, req) |> should.be_ok
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_h2_server", "start")
fn h2_server() -> Int

pub fn observed_h2_cancellation_preserves_sibling_and_one_connection_test() {
  let observer = observer("http-gun-h2-observer")
  let defaults = local_config()
  let settings =
    config.Config(
      ..defaults,
      protocol: config.RequireHttp2,
      trust: config.CustomCa("test/fixtures/ca.crt"),
      observations: Some(observer.target),
      limits: config.Limits(..defaults.limits, connections: 1, per_origin: 1),
    )
  let assert Ok(client) = http_gun.start(settings)
  let port = h2_server()
  let req =
    request.new()
    |> request.set_host("localhost")
    |> request.set_port(port)
    |> request.set_body(<<>>)
  let slow_tag = telemetry.new_id()
  let fast_tag = telemetry.new_id()
  let assert Ok(slow) =
    http_gun.open(
      http_gun.with_correlation(client, slow_tag),
      request.set_path(req, "/slow"),
    )
  let assert Ok(fast) =
    http_gun.open(
      http_gun.with_correlation(client, fast_tag),
      request.set_path(req, "/fast"),
    )
  body.protocol(slow.body) |> should.equal(config.H2)
  list.key_find(slow.headers, "x-connection")
  |> should.equal(list.key_find(fast.headers, "x-connection"))
  let _ = body.close(slow.body)
  let _ = body.close(slow.body)
  body.next(fast.body, 1000) |> should.equal(Ok(body.Chunk(<<0, 255, 128>>)))
  body.next(fast.body, 1000) |> should.equal(Ok(body.End([])))
  let _ = body.close(fast.body)
  let outcomes = terminations(observer, 2, 16)
  list.length(outcomes) |> should.equal(2)
  let assert Ok(slow_end) =
    list.find(outcomes, fn(value) { value.correlation == Some(slow_tag) })
  slow_end.milestone
  |> should.equal(telemetry.HttpTerminated(telemetry.LocallyCancelled))
  let assert Ok(fast_end) =
    list.find(outcomes, fn(value) { value.correlation == Some(fast_tag) })
  fast_end.milestone
  |> should.equal(telemetry.HttpTerminated(telemetry.Complete))
  { slow_end.request_id != fast_end.request_id } |> should.be_true
  let assert Ok(stats) = http_gun.snapshot(client)
  stats.connections |> should.equal(1)
  let _ = http_gun.stop(client)
  stop_observer(observer)
}

fn terminations(
  observer: Observer,
  count: Int,
  remaining: Int,
) -> List(telemetry.Metadata) {
  case count {
    0 -> []
    _ -> {
      let assert True = remaining > 0
      let assert Ok(#(_, metadata)) = process.receive(observer.events, 1000)
      case metadata.milestone {
        telemetry.HttpTerminated(_) -> [
          metadata,
          ..terminations(observer, count - 1, remaining - 1)
        ]
        _ -> terminations(observer, count, remaining - 1)
      }
    }
  }
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
