import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
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

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "http_gun_measure_ffi", "reductions")
fn reductions() -> Int

@external(erlang, "http_gun_measure_ffi", "now")
fn now_us() -> Int

@external(erlang, "http_gun_test_server", "observed")
fn observed() -> Int

@external(erlang, "http_gun_test_server", "next_observed")
fn next_observed() -> String

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

@external(erlang, "erlang", "suspend_process")
fn suspend(pid: process.Pid) -> Bool

@external(erlang, "erlang", "resume_process")
fn resume(pid: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn queued(client: http_gun.Client, expected: Int, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.queued_requests == expected {
        True -> True
        False -> queued(client, expected, tries - 1)
      }
    }
  }
}

fn reason_and_evidence(
  failure: error.Failure,
) -> #(error.Reason, error.Evidence) {
  #(error.reason(failure), error.evidence(failure))
}

pub fn origin_fairness_and_queue_limit_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_max_connections(2)
      |> config.with_max_connections_per_origin(1)
      |> config.with_max_queued_requests(1)
      // Cancel the open slow body at once on stop; draining has its own tests.
      |> config.with_shutdown_timeout(duration.milliseconds(0)),
    )
  let assert Ok(slow) = http_gun.open(client, req(port))
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, http_gun.send(client, req(port)))
    })
  queued(client, 1, 1000) |> should.be_true
  let assert Error(failure) = http_gun.send(client, req(port))
  error.reason(failure) |> should.equal(error.AdmissionFull)
  let fast_port = persistent()
  let assert Ok(fast) = http_gun.send(client, req(fast_port))
  fast.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
  let assert Ok(Error(queued_failure)) = process.receive(result, 1000)
  reason_and_evidence(queued_failure)
  |> should.equal(#(error.ClientClosed, error.NotSent))
  closed(server) |> should.be_true
  body.next_within(slow.body, duration.milliseconds(0)) |> should.be_error
}

pub fn queued_deadline_is_not_submitted_test() {
  let #(port, _) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(150)))
      |> config.with_max_open_bodies(1),
    )
  let assert Ok(slow) = http_gun.open(client, req(port))
  let assert Error(failure) = http_gun.send(client, req(port))
  error.evidence(failure) |> should.equal(error.NotSent)
  error.reason(failure) |> should.equal(error.DeadlineExceeded)
  body.close(slow.body)
  http_gun.stop(client)
}

pub fn pool_timeout_fails_request_waiting_for_slot_test() {
  let #(port, _) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_pool_timeout(duration.milliseconds(100))
      |> config.with_max_open_bodies(1),
    )
  let assert Ok(held) = http_gun.open(client, req(port))
  let started = now_us()
  let assert Error(failure) = http_gun.send(client, req(persistent()))
  let waited = now_us() - started
  reason_and_evidence(failure)
  |> should.equal(#(error.PoolTimeout, error.NotSent))
  error.kind(failure) |> should.equal(error.Unavailable)
  { waited >= 90_000 && waited < 2_000_000 } |> should.be_true
  queued(client, 0, 1000) |> should.be_true
  body.close(held.body)
  // The slot is free again.
  let assert Ok(reply) = http_gun.send(client, req(persistent()))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn idle_pooled_connection_closes_after_connection_idle_timeout_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_connection_idle_timeout(duration.milliseconds(100)),
    )
  let port = persistent()
  let assert Ok(_) = http_gun.send(client, req(port))
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(1)
  await_connections(client, 0, 100) |> should.be_true
  // A later request opens a fresh connection.
  let assert Ok(_) = http_gun.send(client, req(port))
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(1)
  http_gun.stop(client)
}

fn await_connections(
  client: http_gun.Client,
  expected: Int,
  tries: Int,
) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.stats(client)
      case stats.connections == expected {
        True -> True
        False -> {
          process.sleep(20)
          await_connections(client, expected, tries - 1)
        }
      }
    }
  }
}

pub fn supervision_accepts_standard_child_test() {
  let name = process.new_name("http_gun_pool_test_child")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(local_config(), name))
    |> static_supervisor.start
  let assert Ok(stats) = http_gun.stats(http_gun.named(name))
  stats.connections |> should.equal(0)
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
}

pub fn supervised_invalid_config_fails_child_start_test() {
  let name = process.new_name("http_gun_pool_test_invalid_child")
  let outcome = process.new_subject()
  // A failed supervisor start exits its linked caller; trap that exit in a
  // separate process so it reaches the test as a value.
  let _ =
    process.spawn_unlinked(fn() {
      process.trap_exits(True)
      let started =
        static_supervisor.new(static_supervisor.OneForOne)
        |> static_supervisor.add(http_gun.supervised(
          local_config() |> config.with_max_connections(0),
          name,
        ))
        |> static_supervisor.start
      process.send(outcome, started |> result.is_error)
    })
  process.receive(outcome, 2000) |> should.equal(Ok(True))
  process.named(name) |> should.equal(Error(Nil))
}

fn await_restart(
  name: process.Name(http_gun.Message),
  old: process.Pid,
  tries: Int,
) -> Result(process.Pid, Nil) {
  case tries, process.named(name) {
    0, _ -> Error(Nil)
    _, Ok(pid) if pid != old -> Ok(pid)
    _, _ -> {
      process.sleep(10)
      await_restart(name, old, tries - 1)
    }
  }
}

fn await_unregistered(
  name: process.Name(http_gun.Message),
  tries: Int,
) -> Bool {
  case tries, process.named(name) {
    0, _ -> False
    _, Error(Nil) -> True
    _, Ok(_) -> {
      process.sleep(10)
      await_unregistered(name, tries - 1)
    }
  }
}

// A named handle outlives the process behind it: while the supervisor has
// not restarted the client, calls fail with ClientClosed and NotSent; after
// the restart the same handle works again.
pub fn named_handle_survives_supervised_restart_test() {
  let name = process.new_name("http_gun_pool_test_restart")
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(local_config(), name))
    |> static_supervisor.start
  let client = http_gun.named(name)
  let port = persistent()
  let assert Ok(first) = http_gun.send(client, req(port))
  first.response.body |> should.equal(<<"abc":utf8>>)
  let assert Ok(old) = process.named(name)
  // Hold the supervisor so the restart window stays open while we look.
  suspend(supervisor.pid) |> should.be_true
  process.kill(old)
  let unregistered = await_unregistered(name, 200)
  let during_send = http_gun.send(client, req(port))
  let during_stats = http_gun.stats(client)
  resume(supervisor.pid) |> should.be_true
  let restarted = await_restart(name, old, 200)
  let again = http_gun.send(client, req(port))
  let after = http_gun.stats(client)
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
  unregistered |> should.be_true
  let assert Error(stats_failure) = during_stats
  reason_and_evidence(stats_failure)
  |> should.equal(#(error.ClientClosed, error.NotSent))
  restarted |> should.be_ok
  let assert Ok(again) = again
  again.response.body |> should.equal(<<"abc":utf8>>)
  let assert Ok(after) = after
  after.open_bodies |> should.equal(0)
  // Nothing reached the network while no client was registered.
  let assert Error(send_failure) = during_send
  reason_and_evidence(send_failure)
  |> should.equal(#(error.ClientClosed, error.NotSent))
}

fn spawn_stop(client: http_gun.Client) -> process.Subject(Nil) {
  let stopped = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      http_gun.stop(client)
      process.send(stopped, Nil)
    })
  stopped
}

// Send to a fast origin until the client refuses new work, which shows that
// stop has begun draining. Returns that refusal.
fn await_draining(
  client: http_gun.Client,
  port: Int,
  tries: Int,
) -> Result(error.Failure, Nil) {
  case tries, http_gun.send(client, req(port)) {
    0, _ -> Error(Nil)
    _, Ok(_) -> {
      process.sleep(5)
      await_draining(client, port, tries - 1)
    }
    _, Error(failure) ->
      case error.reason(failure) {
        error.ClientClosed -> Ok(failure)
        _ -> Error(Nil)
      }
  }
}

pub fn stop_lets_open_body_finish_within_shutdown_timeout_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_shutdown_timeout(duration.milliseconds(5000)),
    )
  let assert Ok(open) = http_gun.open(client, req(port))
  let #(guard_port, _) = controlled()
  let assert Ok(guard) = http_gun.open(client, req(guard_port))
  let started = now_us()
  let stopped = spawn_stop(client)
  let assert Ok(_) = await_draining(client, persistent(), 200)
  // Draining waits for the open body.
  process.receive(stopped, 100) |> should.equal(Error(Nil))
  emit(server, <<"3\r\nabc\r\n0\r\n\r\n":utf8>>)
  body.next_within(open.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(<<"abc":utf8>>))))
  body.next_within(open.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.End([]))))
  // EOF releases the HTTP lease. Keep another exchange active until the
  // completed body is consumed: stopping the pool ends retained body access.
  process.receive(stopped, 0) |> should.equal(Error(Nil))
  body.close(open.body)
  body.close(guard.body)
  // Closing the final active exchange ends the drain before its timeout.
  process.receive(stopped, 1000) |> should.equal(Ok(Nil))
  { now_us() - started < 3_000_000 } |> should.be_true
}

pub fn stop_fails_queued_requests_not_sent_test() {
  let #(port, _) = controlled()
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_open_bodies(1))
  let assert Ok(held) = http_gun.open(client, req(port))
  let done = process.new_subject()
  let fast = persistent()
  list.each(list.repeat(Nil, 3), fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(done, http_gun.send(client, req(fast)))
      })
    Nil
  })
  queued(client, 3, 1000) |> should.be_true
  let stopped = spawn_stop(client)
  list.each(list.repeat(Nil, 3), fn(_) {
    let assert Ok(Error(failure)) = process.receive(done, 1000)
    reason_and_evidence(failure)
    |> should.equal(#(error.ClientClosed, error.NotSent))
  })
  // The held body is still open, so stop keeps draining.
  process.receive(stopped, 100) |> should.equal(Error(Nil))
  body.close(held.body)
  process.receive(stopped, 1000) |> should.equal(Ok(Nil))
}

pub fn new_requests_during_draining_fail_not_sent_test() {
  let #(port, _) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(held) = http_gun.open(client, req(port))
  let fast = persistent()
  let stopped = spawn_stop(client)
  let assert Ok(refused) = await_draining(client, fast, 200)
  reason_and_evidence(refused)
  |> should.equal(#(error.ClientClosed, error.NotSent))
  let assert Error(open_failure) = http_gun.open(client, req(fast))
  reason_and_evidence(open_failure)
  |> should.equal(#(error.ClientClosed, error.NotSent))
  let assert Ok([Error(batch_failure)]) = http_gun.batch(client, [req(fast)], 1)
  reason_and_evidence(batch_failure)
  |> should.equal(#(error.ClientClosed, error.NotSent))
  process.receive(stopped, 50) |> should.equal(Error(Nil))
  body.close(held.body)
  process.receive(stopped, 1000) |> should.equal(Ok(Nil))
  // A stopped client keeps refusing.
  let assert Error(after) = http_gun.send(client, req(fast))
  error.reason(after) |> should.equal(error.ClientClosed)
}

pub fn shutdown_timeout_cancels_body_that_never_finishes_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config() |> config.with_shutdown_timeout(duration.milliseconds(200)),
    )
  let assert Ok(open) = http_gun.open(client, req(port))
  let started = now_us()
  http_gun.stop(client)
  let waited = now_us() - started
  { waited >= 190_000 && waited < 2_000_000 } |> should.be_true
  let assert Error(failure) =
    body.next_within(open.body, duration.milliseconds(1000))
  error.evidence(failure) |> should.equal(error.MaybeSent)
  closed(server) |> should.be_true
  body.close(open.body)
}

pub fn batch_bytes_beyond_limit_fail_later_positions_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_batch_bytes(4))
  // Each response body is 3 bytes; one worker makes the order deterministic.
  let assert Ok(results) = http_gun.batch(client, list.repeat(req(port), 4), 1)
  let assert [Ok(first), Error(crossing), Error(third), Error(fourth)] = results
  first.response.body |> should.equal(<<"abc":utf8>>)
  let assert error.LimitExceeded(error.BatchBytes, 4, _) =
    error.reason(crossing)
  list.each([third, fourth], fn(failure) {
    let assert error.LimitExceeded(error.BatchBytes, 4, observed) =
      error.reason(failure)
    { observed > 4 } |> should.be_true
    error.evidence(failure) |> should.equal(error.NotSent)
    error.kind(failure) |> should.equal(error.TooLarge)
  })
  // The bound belongs to one batch call.
  let assert Ok([Ok(_)]) = http_gun.batch(client, [req(port)], 1)
  http_gun.stop(client)
}

pub fn idle_connection_yields_capacity_to_other_origin_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(500)))
      |> config.with_max_connections(1),
    )
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  http_gun.stop(client)
}

fn burst(client: http_gun.Client, port: Int, count: Int) -> Int {
  let done = process.new_subject()
  let started = reductions()
  list.each(list.repeat(Nil, count), fn(_) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(done, http_gun.send(client, req(port)))
      })
    Nil
  })
  list.each(list.repeat(Nil, count), fn(_) {
    let assert Ok(Ok(reply)) = process.receive(done, 5000)
    reply.response.body |> should.equal(<<"abc":utf8>>)
  })
  reductions() - started
}

pub fn burst_work_scales_with_requests_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(
        config.After(duration.milliseconds(10_000)),
      )
      |> config.with_max_connections(4)
      |> config.with_max_connections_per_origin(4)
      |> config.with_max_open_bodies(1024)
      |> config.with_max_queued_requests(1024),
    )
  let port = persistent()
  // Warm transport and all four connections before counting VM work.
  let _ = burst(client, port, 100)
  let small = burst(client, port, 500)
  let large = burst(client, port, 1000)
  http_gun.stop(client)
  // Doubling inputs must not produce the old quadratic admission work.
  { large < small * 3 } |> should.be_true
}

fn spawn_request(
  client: http_gun.Client,
  request: request.Request(BitArray),
  done: process.Subject(Result(http_gun.Buffered, error.Failure)),
) -> process.Pid {
  process.spawn_unlinked(fn() {
    process.send(done, http_gun.send(client, request))
  })
}

pub fn cancelled_queue_entries_preserve_fifo_and_restore_capacity_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_max_open_bodies(1)
      |> config.with_max_queued_requests(3)
      |> config.with_max_connections(1),
    )
  let port = observed()
  let assert Ok(held) =
    http_gun.open(client, request.set_path(req(port), "/held"))
  next_observed() |> should.equal("/held")
  let done = process.new_subject()
  let first = spawn_request(client, request.set_path(req(port), "/first"), done)
  queued(client, 1, 1000) |> should.be_true
  let middle =
    spawn_request(client, request.set_path(req(port), "/middle"), done)
  queued(client, 2, 1000) |> should.be_true
  let last = spawn_request(client, request.set_path(req(port), "/last"), done)
  queued(client, 3, 1000) |> should.be_true
  process.send_abnormal_exit(middle, "cancel queued caller")
  queued(client, 2, 1000) |> should.be_true
  process.send_abnormal_exit(last, "cancel queued caller")
  queued(client, 1, 1000) |> should.be_true
  let _ =
    spawn_request(
      client,
      req(port) |> request.set_path("/next") |> request.set_host("LOCALHOST"),
      done,
    )
  queued(client, 2, 1000) |> should.be_true
  let _ = spawn_request(client, request.set_path(req(port), "/final"), done)
  queued(client, 3, 1000) |> should.be_true
  process.send_abnormal_exit(first, "cancel queued caller")
  queued(client, 2, 1000) |> should.be_true
  body.close(held.body)
  next_observed() |> should.equal("/next")
  next_observed() |> should.equal("/final")
  let assert Ok(Ok(_)) = process.receive(done, 1000)
  let assert Ok(Ok(_)) = process.receive(done, 1000)
  queued(client, 0, 1000) |> should.be_true
  let assert Ok(_) =
    http_gun.send(client, request.set_path(req(port), "/after"))
  next_observed() |> should.equal("/after")
  http_gun.stop(client)
}

pub fn blocked_origin_backlog_allows_another_origin_test() {
  let #(port, server) = controlled()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_max_connections(2)
      |> config.with_max_connections_per_origin(1)
      |> config.with_max_queued_requests(500),
    )
  let assert Ok(held) = http_gun.open(client, req(port))
  let done = process.new_subject()
  list.each(list.repeat(Nil, 500), fn(_) {
    let _ = spawn_request(client, req(port), done)
    Nil
  })
  queued(client, 500, 2000) |> should.be_true
  let assert Ok(fast) = http_gun.send(client, req(persistent()))
  fast.response.body |> should.equal(<<"abc":utf8>>)
  body.close(held.body)
  http_gun.stop(client)
  list.each(list.repeat(Nil, 500), fn(_) {
    let assert Ok(Error(_)) = process.receive(done, 1000)
    Nil
  })
  closed(server) |> should.be_true
}

pub fn queued_deadlines_remove_entries_and_restore_capacity_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_request_timeout(config.After(duration.milliseconds(150)))
      |> config.with_max_open_bodies(1)
      |> config.with_max_queued_requests(32),
    )
  let port = persistent()
  let assert Ok(held) = http_gun.open(client, req(port))
  let done = process.new_subject()
  list.each(list.repeat(Nil, 32), fn(_) {
    let _ = spawn_request(client, req(port), done)
    Nil
  })
  queued(client, 32, 1000) |> should.be_true
  list.each(list.repeat(Nil, 32), fn(_) {
    let assert Ok(Error(failure)) = process.receive(done, 1000)
    error.reason(failure) |> should.equal(error.DeadlineExceeded)
    error.evidence(failure) |> should.equal(error.NotSent)
  })
  queued(client, 0, 1000) |> should.be_true
  body.close(held.body)
  let assert Ok(reply) = http_gun.send(client, req(port))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn eligible_origins_take_turns_under_shared_body_capacity_test() {
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_open_bodies(1))
  let one = observed()
  let two = observed()
  let a = int.min(one, two)
  let b = int.max(one, two)
  let assert Ok(_) = http_gun.send(client, request.set_path(req(b), "/warm-b"))
  next_observed() |> should.equal("/warm-b")
  let assert Ok(held) = http_gun.open(client, request.set_path(req(a), "/held"))
  next_observed() |> should.equal("/held")
  // Retain the completed handle but make both connections eligible.
  body.next_within(held.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.Chunk(<<"abc":utf8>>))))
  body.next_within(held.body, duration.milliseconds(1000))
  |> should.equal(Ok(Some(body.End([]))))
  let done = process.new_subject()
  let _ = spawn_request(client, request.set_path(req(a), "/a1"), done)
  queued(client, 1, 1000) |> should.be_true
  let _ = spawn_request(client, request.set_path(req(a), "/a2"), done)
  queued(client, 2, 1000) |> should.be_true
  let _ = spawn_request(client, request.set_path(req(b), "/b"), done)
  queued(client, 3, 1000) |> should.be_true
  body.close(held.body)
  next_observed() |> should.equal("/a1")
  next_observed() |> should.equal("/b")
  next_observed() |> should.equal("/a2")
  list.each(list.repeat(Nil, 3), fn(_) {
    let assert Ok(Ok(_)) = process.receive(done, 1000)
    Nil
  })
  http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
