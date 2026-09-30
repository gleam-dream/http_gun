import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/otp/static_supervisor
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "http_gun_measure_ffi", "reductions")
fn reductions() -> Int

@external(erlang, "http_gun_test_server", "observed")
fn observed() -> Int

@external(erlang, "http_gun_test_server", "next_observed")
fn next_observed() -> String

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn queued(client: http_gun.Client, expected: Int, tries: Int) -> Bool {
  case tries {
    0 -> False
    _ -> {
      let assert Ok(stats) = http_gun.snapshot(client)
      case stats.waiting == expected {
        True -> True
        False -> queued(client, expected, tries - 1)
      }
    }
  }
}

pub fn origin_fairness_and_queue_limit_test() {
  let #(port, server) = controlled()
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        limits: config.Limits(
          ..c.limits,
          connections: 2,
          per_origin: 1,
          waiting: 1,
        ),
      ),
    )
  let assert Ok(slow) = http_gun.open(client, req(port))
  let result = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(result, http_gun.send(client, req(port)))
    })
  queued(client, 1, 1000) |> should.be_true
  let assert Error(failure) = http_gun.send(client, req(port))
  failure.reason |> should.equal(error.AdmissionFull)
  let fast_port = persistent()
  let assert Ok(fast) = http_gun.send(client, req(fast_port))
  fast.response.body |> should.equal(<<"abc":utf8>>)
  let _ = http_gun.stop(client)
  let assert Ok(Error(_)) = process.receive(result, 1000)
  closed(server) |> should.be_true
  body.next(slow.body, 0) |> should.be_error
}

pub fn queued_deadline_is_not_submitted_test() {
  let #(port, _) = controlled()
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        deadline_ms: 150,
        limits: config.Limits(..c.limits, active: 1),
      ),
    )
  let assert Ok(slow) = http_gun.open(client, req(port))
  let assert Error(failure) = http_gun.send(client, req(port))
  failure.evidence |> should.equal(error.NotSubmitted)
  failure.reason |> should.equal(error.DeadlineExceeded)
  let _ = body.close(slow.body)
  let _ = http_gun.stop(client)
}

pub fn supervision_accepts_standard_child_test() {
  let child = http_gun.child(config.default())
  let assert Ok(supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(child)
    |> static_supervisor.start
  process.unlink(supervisor.pid)
  process.send_exit(supervisor.pid)
}

pub fn idle_connection_yields_capacity_to_other_origin_test() {
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        deadline_ms: 500,
        limits: config.Limits(..c.limits, connections: 1),
      ),
    )
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  let assert Ok(_) = http_gun.send(client, req(persistent()))
  let _ = http_gun.stop(client)
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
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        deadline_ms: 10_000,
        limits: config.Limits(
          ..c.limits,
          connections: 4,
          per_origin: 4,
          active: 1024,
          waiting: 1024,
        ),
      ),
    )
  let port = persistent()
  // Warm transport and all four connections before counting VM work.
  let _ = burst(client, port, 100)
  let small = burst(client, port, 500)
  let large = burst(client, port, 1000)
  let _ = http_gun.stop(client)
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
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        limits: config.Limits(..c.limits, active: 1, waiting: 3, connections: 1),
      ),
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
  body.close(held.body) |> should.be_ok
  next_observed() |> should.equal("/next")
  next_observed() |> should.equal("/final")
  let assert Ok(Ok(_)) = process.receive(done, 1000)
  let assert Ok(Ok(_)) = process.receive(done, 1000)
  queued(client, 0, 1000) |> should.be_true
  let assert Ok(_) =
    http_gun.send(client, request.set_path(req(port), "/after"))
  next_observed() |> should.equal("/after")
  let _ = http_gun.stop(client)
}

pub fn blocked_origin_backlog_allows_another_origin_test() {
  let #(port, server) = controlled()
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        limits: config.Limits(
          ..c.limits,
          connections: 2,
          per_origin: 1,
          waiting: 500,
        ),
      ),
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
  body.close(held.body) |> should.be_ok
  let _ = http_gun.stop(client)
  list.each(list.repeat(Nil, 500), fn(_) {
    let assert Ok(Error(_)) = process.receive(done, 1000)
    Nil
  })
  closed(server) |> should.be_true
}

pub fn queued_deadlines_remove_entries_and_restore_capacity_test() {
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        deadline_ms: 150,
        limits: config.Limits(..c.limits, active: 1, waiting: 32),
      ),
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
    failure.reason |> should.equal(error.DeadlineExceeded)
    failure.evidence |> should.equal(error.NotSubmitted)
  })
  queued(client, 0, 1000) |> should.be_true
  let _ = body.close(held.body)
  let assert Ok(reply) = http_gun.send(client, req(port))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let _ = http_gun.stop(client)
}

pub fn eligible_origins_take_turns_under_shared_body_capacity_test() {
  let c = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, limits: config.Limits(..c.limits, active: 1)),
    )
  let one = observed()
  let two = observed()
  let a = int.min(one, two)
  let b = int.max(one, two)
  let assert Ok(_) = http_gun.send(client, request.set_path(req(b), "/warm-b"))
  next_observed() |> should.equal("/warm-b")
  let assert Ok(held) = http_gun.open(client, request.set_path(req(a), "/held"))
  next_observed() |> should.equal("/held")
  // Retain the completed handle but make both connections eligible.
  body.next(held.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  body.next(held.body, 1000) |> should.equal(Ok(body.End([])))
  let done = process.new_subject()
  let _ = spawn_request(client, request.set_path(req(a), "/a1"), done)
  queued(client, 1, 1000) |> should.be_true
  let _ = spawn_request(client, request.set_path(req(a), "/a2"), done)
  queued(client, 2, 1000) |> should.be_true
  let _ = spawn_request(client, request.set_path(req(b), "/b"), done)
  queued(client, 3, 1000) |> should.be_true
  let _ = body.close(held.body)
  next_observed() |> should.equal("/a1")
  next_observed() |> should.equal("/b")
  next_observed() |> should.equal("/a2")
  list.each(list.repeat(Nil, 3), fn(_) {
    let assert Ok(Ok(_)) = process.receive(done, 1000)
    Nil
  })
  let _ = http_gun.stop(client)
}
