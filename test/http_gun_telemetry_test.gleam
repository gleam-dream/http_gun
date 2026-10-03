import gleam/dynamic.{type Dynamic}
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/telemetry
import http_gun/testing
import sinal
import sinal/correlation
import sinal/fields
import sinal/forwarder

fn script_of(exchange: testing.Exchange, count: Int) -> testing.Script {
  testing.script(list.repeat(exchange, count))
}

fn no_content(req: request.Request(BitArray)) -> testing.Exchange {
  testing.exchange(
    req,
    testing.Respond(response.Response(204, [], []), testing.Finished([])),
  )
}

pub fn scripted_lifecycle_has_correlation_without_network_submission_test() {
  let fwd =
    forwarder.new(process.new_name("http-gun-observations"))
    |> forwarder.with_capacity(32)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      process.send(events, #(time, metadata))
    })
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    testing.exchange(
      req,
      testing.Respond(
        response.Response(201, [], [<<0, 255>>]),
        testing.Finished([]),
      ),
    )
  let settings = local_config() |> config.with_observations(fwd)
  let assert Ok(shared) = testing.playback(testing.script([exchange]), settings)
  let assert Ok(correlation) = correlation.from_string("order-42")
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
  http_gun.stop(shared)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
}

// Regression for HTTPGUN-R8: `correlation` holds the caller's Sinal value, so
// a handler that knows only `correlation.field()` joins HTTP events with other
// packages' events. HTTP Gun's own identity lives under `request_id`.
pub fn native_metadata_carries_caller_correlation_and_request_id_test() {
  let fwd =
    forwarder.new(process.new_name("http-gun-native-observations"))
    |> forwarder.with_capacity(64)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let native = process.new_subject()
  attach_native("http-gun-native-metadata-test", native)
  let req = request.new() |> request.set_body(<<>>)
  let settings = local_config() |> config.with_observations(fwd)
  let assert Ok(shared) =
    testing.playback(script_of(no_content(req), 3), settings)
  let assert Ok(replaced) = correlation.from_string("replaced")
  let assert Ok(order) = correlation.from_string("order-42")
  // A later with_correlation replaces the view's value.
  let client =
    shared
    |> http_gun.with_correlation(replaced)
    |> http_gun.with_correlation(order)
  let assert Ok(_) = http_gun.send(client, req)
  let correlated_first = receive_native(native, 4)
  let assert Ok(_) = http_gun.send(client, req)
  let correlated_second = receive_native(native, 4)
  let assert Ok(_) = http_gun.send(shared, req)
  let uncorrelated = receive_native(native, 4)
  list.append(correlated_first, correlated_second)
  |> list.each(fn(raw) {
    fields.decode(correlation.field(), raw) |> should.equal(Ok(Some(order)))
    native_key(raw, "correlation") |> should.equal(Ok("order-42"))
  })
  list.each(uncorrelated, fn(raw) {
    fields.decode(correlation.field(), raw) |> should.equal(Ok(None))
    native_key(raw, "correlation") |> should.equal(Error(Nil))
  })
  // One request_id per invocation, shared by its milestones, distinct across
  // invocations that reuse a correlation.
  let first_id = single_request_id(correlated_first)
  let second_id = single_request_id(correlated_second)
  let third_id = single_request_id(uncorrelated)
  { first_id != second_id && second_id != third_id && first_id != third_id }
  |> should.be_true
  detach_native("http-gun-native-metadata-test")
  http_gun.stop(shared)
  process.unlink(started.pid)
  process.kill(started.pid)
}

@external(erlang, "http_gun_telemetry_test_ffi", "attach_native")
fn attach_native(id: String, subject: process.Subject(Dynamic)) -> Nil

@external(erlang, "http_gun_telemetry_test_ffi", "detach_native")
fn detach_native(id: String) -> Nil

fn receive_native(
  subject: process.Subject(Dynamic),
  remaining: Int,
) -> List(Dynamic) {
  case remaining {
    0 -> []
    _ -> {
      let assert Ok(raw) = process.receive(subject, 1000)
      [raw, ..receive_native(subject, remaining - 1)]
    }
  }
}

fn native_key(raw: Dynamic, key: String) -> Result(String, Nil) {
  fields.decode(fields.string(key), raw) |> result.replace_error(Nil)
}

fn single_request_id(events: List(Dynamic)) -> String {
  let assert [first, ..] = events
  let assert Ok(id) = native_key(first, "request_id")
  list.each(events, fn(raw) {
    native_key(raw, "request_id") |> should.equal(Ok(id))
  })
  id
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

// Events of one correlated request, with the process each handler ran in.
// Filtering by correlation keeps events of unrelated clients out.
fn receive_tagged(
  subject: process.Subject(#(process.Pid, telemetry.Metadata)),
  tag: correlation.Correlation,
  remaining: Int,
) -> List(#(process.Pid, telemetry.Metadata)) {
  case remaining {
    0 -> []
    _ ->
      case process.receive(subject, 1000) {
        Error(Nil) -> []
        Ok(#(_, metadata) as event) ->
          case metadata.correlation == Some(tag) {
            True -> [event, ..receive_tagged(subject, tag, remaining - 1)]
            False -> receive_tagged(subject, tag, remaining)
          }
      }
  }
}

fn attach_with_pid(
  subject: process.Subject(#(process.Pid, telemetry.Metadata)),
) -> sinal.Attachment {
  sinal.observe(telemetry.event(), fn(_, metadata) {
    process.send(subject, #(process.self(), metadata))
  })
}

fn has_offline_milestones(
  events: List(#(process.Pid, telemetry.Metadata)),
) -> Bool {
  let seen = list.map(events, fn(event) { { event.1 }.milestone })
  list.all(
    [
      telemetry.AdmissionEntered,
      telemetry.AdmissionGranted,
      telemetry.ResponseHeaders(204),
      telemetry.HttpTerminated(telemetry.Complete),
    ],
    list.contains(seen, _),
  )
}

// Without with_observations a client emits through sinal.emit: with no route
// for ["http_gun"], a handler runs synchronously in HTTP Gun's own pool and
// body processes, never in the caller.
pub fn default_client_delivers_events_to_sinal_handler_test() {
  let events = process.new_subject()
  let attachment = attach_with_pid(events)
  let req = request.new() |> request.set_body(<<>>)
  let assert Ok(shared) =
    testing.playback(script_of(no_content(req), 1), local_config())
  let tag = correlation.unique()
  let sent = http_gun.send(http_gun.with_correlation(shared, tag), req)
  let seen = receive_tagged(events, tag, 4)
  http_gun.stop(shared)
  let assert Ok(Nil) = sinal.detach(attachment)
  let assert Ok(reply) = sent
  reply.response.status |> should.equal(204)
  list.length(seen) |> should.equal(4)
  has_offline_milestones(seen) |> should.be_true
  list.each(seen, fn(event) {
    { event.0 != process.self() } |> should.be_true
    { event.1 }.mode |> should.equal(telemetry.Offline)
  })
}

// forwarder.route(["http_gun"], fwd) moves default delivery into fwd: every
// handler then runs in the forwarder's process.
pub fn route_moves_default_delivery_into_forwarder_test() {
  let fwd =
    forwarder.new(process.new_name("http-gun-routed-observations"))
    |> forwarder.with_capacity(64)
  let assert Ok(started) = forwarder.supervised(fwd).start()
  let events = process.new_subject()
  let attachment = attach_with_pid(events)
  let req = request.new() |> request.set_body(<<>>)
  let assert Ok(shared) =
    testing.playback(script_of(no_content(req), 2), local_config())
  // Unrouted first, for contrast.
  let before = correlation.unique()
  let first = http_gun.send(http_gun.with_correlation(shared, before), req)
  let unrouted = receive_tagged(events, before, 4)
  forwarder.route(["http_gun"], fwd)
  let after = correlation.unique()
  let second = http_gun.send(http_gun.with_correlation(shared, after), req)
  let routed = receive_tagged(events, after, 4)
  // Undo the node-global route before asserting, so a failure cannot leak it.
  forwarder.unroute(["http_gun"])
  http_gun.stop(shared)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(started.pid)
  process.kill(started.pid)
  first |> should.be_ok
  second |> should.be_ok
  list.length(unrouted) |> should.equal(4)
  list.each(unrouted, fn(event) { { event.0 != started.pid } |> should.be_true })
  list.length(routed) |> should.equal(4)
  has_offline_milestones(routed) |> should.be_true
  list.each(routed, fn(event) { event.0 |> should.equal(started.pid) })
}

// config.with_observations sends one client's events to its own forwarder,
// even when the application routed ["http_gun"] elsewhere.
pub fn with_observations_sends_to_its_forwarder_test() {
  let own =
    forwarder.new(process.new_name("http-gun-own-observations"))
    |> forwarder.with_capacity(64)
  let other =
    forwarder.new(process.new_name("http-gun-other-observations"))
    |> forwarder.with_capacity(64)
  let assert Ok(own_started) = forwarder.supervised(own).start()
  let assert Ok(other_started) = forwarder.supervised(other).start()
  let events = process.new_subject()
  let attachment = attach_with_pid(events)
  let req = request.new() |> request.set_body(<<>>)
  let assert Ok(shared) =
    testing.playback(
      script_of(no_content(req), 2),
      local_config() |> config.with_observations(own),
    )
  let unrouted_tag = correlation.unique()
  let first =
    http_gun.send(http_gun.with_correlation(shared, unrouted_tag), req)
  let unrouted = receive_tagged(events, unrouted_tag, 4)
  forwarder.route(["http_gun"], other)
  let routed_tag = correlation.unique()
  let second = http_gun.send(http_gun.with_correlation(shared, routed_tag), req)
  let overridden = receive_tagged(events, routed_tag, 4)
  forwarder.unroute(["http_gun"])
  http_gun.stop(shared)
  let assert Ok(Nil) = sinal.detach(attachment)
  process.unlink(own_started.pid)
  process.kill(own_started.pid)
  process.unlink(other_started.pid)
  process.kill(other_started.pid)
  first |> should.be_ok
  second |> should.be_ok
  list.length(unrouted) |> should.equal(4)
  has_offline_milestones(unrouted) |> should.be_true
  list.length(overridden) |> should.equal(4)
  has_offline_milestones(overridden) |> should.be_true
  list.append(unrouted, overridden)
  |> list.each(fn(event) { event.0 |> should.equal(own_started.pid) })
}

@external(erlang, "http_gun_measure_ffi", "queue_len")
fn queue_len(pid: process.Pid) -> Int

pub fn blocked_observer_drops_without_stalling_bounded_batch_test() {
  let fwd =
    forwarder.new(process.new_name("http-gun-blocked-observer"))
    |> forwarder.with_capacity(1)
  let spec = forwarder.supervised(fwd)
  let assert Ok(started) = spec.start()
  let entered = process.new_subject()
  let finished = process.new_subject()
  let drops = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(_, _) {
      let release = process.new_subject()
      process.send(entered, release)
      process.receive_forever(release)
    })
  let drop_attachment =
    sinal.observe(forwarder.dropped_event(), fn(value, _) {
      process.send(drops, value)
    })
  let req = request.new() |> request.set_body(<<>>)
  let requests = list.repeat(req, 1000)
  let settings = local_config() |> config.with_observations(fwd)
  let assert Ok(client) =
    testing.playback(script_of(no_content(req), 1000), settings)
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
  http_gun.stop(client)
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
  let target =
    forwarder.new(process.new_name(name))
    |> forwarder.with_capacity(64)
  let spec = forwarder.supervised(target)
  let assert Ok(started) = spec.start()
  let events = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
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
  let settings = local_config() |> config.with_observations(observer.target)
  let assert Ok(client) = http_gun.start(settings)
  let #(port, server) = gated()
  let result = process.new_subject()
  cancellation.with_token(fn(token) {
    let cancellable = http_gun.with_cancellation(client, token)
    let _ =
      process.spawn_unlinked(fn() {
        process.send(result, http_gun.send(cancellable, local_request(port)))
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
    error.reason(failure) |> should.equal(error.Cancelled)
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
  http_gun.stop(client)
  stop_observer(observer)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

pub fn queued_deadline_terminates_without_grant_or_gun_return_test() {
  let observer = observer("http-gun-queue-observer")
  let settings =
    local_config()
    |> config.with_observations(observer.target)
    |> config.with_max_connections(1)
    |> config.with_max_connections_per_origin(1)
  let assert Ok(shared) = http_gun.start(settings)
  let #(port, _) = controlled()
  let assert Ok(first) = http_gun.open(shared, local_request(port))
  let _ = until(observer, telemetry.ResponseHeaders(200), 8)
  let result = process.new_subject()
  let correlation = correlation.unique()
  let client =
    shared
    |> http_gun.with_correlation(correlation)
    |> http_gun.with_deadline(deadline.after(1000))
  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, http_gun.send(client, local_request(port)))
    })
  let waiting = until(observer, telemetry.AdmissionWaiting, 8)
  let assert Ok(Error(failure)) = process.receive(result, 2000)
  failure
  |> should.equal(error.new(error.DeadlineExceeded, error.NotSent))
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
  body.close(first.body)
  http_gun.stop(shared)
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
  let settings = local_config() |> config.with_observations(observer.target)
  let req = local_request(server())
  let path = temp_path()
  let assert Ok(recorded) = cassette.record(settings, path, cassette.options())
  let tag = correlation.unique()
  let assert Ok(original) =
    http_gun.send(http_gun.with_correlation(recorded.client, tag), req)
  let live = until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.all(live, fn(value) { value.1.mode == telemetry.Recorded })
  |> should.be_true
  list.any(live, fn(value) { value.1.milestone == telemetry.GunCallReturned })
  |> should.be_true
  let assert Ok(_) = cassette.finish(recorded.recording, 1000)
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 100_000)
  let assert Ok(playback) = testing.playback(tape, settings)
  let assert Error(mismatch) =
    http_gun.send(playback, request.set_path(req, "/different"))
  error.reason(mismatch) |> should.equal(error.PlaybackMismatch(0))
  let rejected = until(observer, telemetry.HttpTerminated(telemetry.Failed), 8)
  list.any(rejected, fn(value) {
    value.1.milestone == telemetry.AdmissionGranted
  })
  |> should.be_false
  // Different correlation, same exact request: mismatch did not consume it.
  let assert Ok(replayed) =
    http_gun.send(
      http_gun.with_correlation(playback, correlation.unique()),
      req,
    )
  replayed.response |> should.equal(original.response)
  let offline = until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.all(offline, fn(value) { value.1.mode == telemetry.Offline })
  |> should.be_true
  list.any(offline, fn(value) { value.1.milestone == telemetry.GunCallReturned })
  |> should.be_false
  http_gun.stop(playback)
  remove_fixture(path)
  // A capture failure does not become an HTTP failure observation.
  let failed_path = temp_path()
  let assert Ok(limited) =
    cassette.record(
      settings,
      failed_path,
      cassette.options() |> cassette.with_max_bytes(1),
    )
  let assert Ok(_) = http_gun.send(limited.client, local_request(server()))
  let captured =
    until(observer, telemetry.HttpTerminated(telemetry.Complete), 8)
  list.any(captured, fn(value) {
    value.1.milestone == telemetry.HttpTerminated(telemetry.Failed)
  })
  |> should.be_false
  cassette.finish(limited.recording, 1000)
  |> should.equal(Error(cassette.CaptureFailed(cassette.CaptureLimit)))
  http_gun.stop(limited.client)
  stop_observer(observer)
}

pub fn unavailable_dead_and_throwing_observers_preserve_http_test() {
  let target =
    forwarder.new(process.new_name("http-gun-fault-observer"))
    |> forwarder.with_capacity(16)
  let settings = local_config() |> config.with_observations(target)
  let req = request.new() |> request.set_body(<<>>)
  let assert Ok(client) =
    testing.playback(script_of(no_content(req), 3), settings)
  http_gun.send(client, req) |> should.be_ok
  let spec = forwarder.supervised(target)
  let assert Ok(started) = spec.start()
  let entered = process.new_subject()
  let failing =
    sinal.observe(telemetry.event(), fn(_, _) {
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
  http_gun.stop(client)
  // Telemetry removes a handler that crashed; detach in case it never ran.
  let _ = sinal.detach(failing)
  Nil
}

@external(erlang, "http_gun_h2_server", "start")
fn h2_server() -> Int

pub fn observed_h2_cancellation_preserves_sibling_and_one_connection_test() {
  let observer = observer("http-gun-h2-observer")
  let settings =
    local_config()
    |> config.with_protocol(config.RequireHttp2)
    |> config.with_trust(config.CustomCa("test/fixtures/ca.crt"))
    |> config.with_observations(observer.target)
    |> config.with_max_connections(1)
    |> config.with_max_connections_per_origin(1)
  let assert Ok(client) = http_gun.start(settings)
  let port = h2_server()
  let req =
    request.new()
    |> request.set_host("localhost")
    |> request.set_port(port)
    |> request.set_body(<<>>)
  let slow_tag = correlation.unique()
  let fast_tag = correlation.unique()
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
  body.close(slow.body)
  body.close(slow.body)
  body.next_within(fast.body, 1000)
  |> should.equal(Ok(Some(body.Chunk(<<0, 255, 128>>))))
  body.next_within(fast.body, 1000) |> should.equal(Ok(Some(body.End([]))))
  body.close(fast.body)
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
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(1)
  http_gun.stop(client)
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
