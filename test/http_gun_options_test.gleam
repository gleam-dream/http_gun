import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/option.{Some}
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/fixture
import http_gun/request_options
import http_gun/testing

pub fn expired_deadline_refuses_before_submission_test() {
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(budget) = deadline.after(0)
  let options =
    request_options.Options(..request_options.default(), deadline: Some(budget))
  let req =
    request.new() |> request.set_host("localhost") |> request.set_body(<<>>)
  let assert Error(failure) = http_gun.send_with_options(client, req, options)
  failure
  |> should.equal(error.Failure(error.DeadlineExceeded, error.NotSubmitted))
  let assert Ok(stats) = http_gun.snapshot(client)
  stats.connections |> should.equal(0)
  let _ = http_gun.stop(client)
}

pub fn cancelled_token_refuses_fresh_work_test() {
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      cancellation.cancel(token)
      cancellation.cancel(token)
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let req =
        request.new() |> request.set_host("localhost") |> request.set_body(<<>>)
      http_gun.send_with_options(client, req, options)
      |> should.equal(Error(error.Failure(error.Cancelled, error.NotSubmitted)))
    })
  let assert Ok(stats) = http_gun.snapshot(client)
  stats.connections |> should.equal(0)
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn await_request(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

pub fn token_cancels_before_headers_without_killing_caller_test() {
  let #(port, server) = gated()
  let assert Ok(client) = http_gun.start(local_config())
  let result = process.new_subject()
  let alive = process.new_subject()
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let _ =
        process.spawn_unlinked(fn() {
          process.send(
            result,
            http_gun.open_with_options(client, req(port), options),
          )
          process.send(alive, Nil)
        })
      await_request(server)
      cancellation.cancel(token)
      let assert Ok(Error(failure)) = process.receive(result, 1000)
      failure
      |> should.equal(error.Failure(error.Cancelled, error.MayHaveBeenSent))
      process.receive(alive, 1000) |> should.equal(Ok(Nil))
      closed(server) |> should.be_true
    })
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

pub fn queued_cancellation_removes_waiter_without_submission_test() {
  let #(port, server) = controlled()
  let c = local_config()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, limits: config.Limits(..c.limits, active: 1)),
    )
  let assert Ok(held) = http_gun.open(client, req(port))
  let result = process.new_subject()
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let _ =
        process.spawn_unlinked(fn() {
          process.send(
            result,
            http_gun.send_with_options(client, req(port), options),
          )
        })
      wait_for_queue(client, 1, 1000) |> should.be_true
      cancellation.cancel(token)
      let assert Ok(Error(failure)) = process.receive(result, 1000)
      failure
      |> should.equal(error.Failure(error.Cancelled, error.NotSubmitted))
      wait_for_queue(client, 0, 1000) |> should.be_true
    })
  let _ = body.close(held.body)
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

fn wait_for_queue(client: http_gun.Client, size: Int, tries: Int) -> Bool {
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.waiting == size, tries {
    True, _ -> True
    False, 0 -> False
    False, _ -> wait_for_queue(client, size, tries - 1)
  }
}

pub fn cancellation_during_tls_setup_releases_connection_reservation_test() {
  let #(port, server) = gated()
  let c = local_config()
  let assert Ok(client) = http_gun.start(config.Config(..c, connect_ms: 500))
  let result = process.new_subject()
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let _ =
        process.spawn_unlinked(fn() {
          process.send(
            result,
            http_gun.send_with_options(
              client,
              req(port) |> request.set_scheme(http.Https),
              options,
            ),
          )
        })
      await_request(server)
      cancellation.cancel(token)
      let assert Ok(Error(failure)) = process.receive(result, 1000)
      failure
      |> should.equal(error.Failure(error.Cancelled, error.NotSubmitted))
      let assert Ok(stats) = http_gun.snapshot(client)
      stats.connections |> should.equal(0)
    })
  let _ = http_gun.stop(client)
}

pub fn supplied_deadline_covers_body_and_client_remains_ceiling_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(budget) = deadline.after(100)
  let options =
    request_options.Options(..request_options.default(), deadline: Some(budget))
  let assert Ok(response) =
    http_gun.open_with_options(client, req(port), options)
  body.next(response.body, 1000)
  |> should.equal(
    Error(error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent)),
  )
  deadline.remaining_ms(budget) |> should.equal(0)
  closed(server) |> should.be_true
  let _ = body.close(response.body)
  let _ = http_gun.stop(client)
  let #(port, server) = controlled()
  let c = local_config()
  let assert Ok(client) = http_gun.start(config.Config(..c, deadline_ms: 100))
  let assert Ok(budget) = deadline.after(5000)
  let options = request_options.Options(..options, deadline: Some(budget))
  let assert Ok(response) =
    http_gun.open_with_options(client, req(port), options)
  body.next(response.body, 1000)
  |> should.equal(
    Error(error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent)),
  )
  closed(server) |> should.be_true
  let _ = body.close(response.body)
  let _ = http_gun.stop(client)
}

pub fn scope_exit_cancels_stream_and_returned_token_stays_cancelled_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(#(response, token)) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let assert Ok(response) =
        http_gun.open_with_options(client, req(port), options)
      #(response, token)
    })
  body.next(response.body, 1000)
  |> should.equal(Error(error.Failure(error.Cancelled, error.MayHaveBeenSent)))
  closed(server) |> should.be_true
  let _ = body.close(response.body)
  let options =
    request_options.Options(
      ..request_options.default(),
      cancellation: Some(token),
    )
  http_gun.send_with_options(client, req(port), options)
  |> should.equal(Error(error.Failure(error.Cancelled, error.NotSubmitted)))
  let _ = http_gun.stop(client)
}

pub fn cancellation_creator_death_unblocks_independent_consumer_test() {
  let #(port, server) = gated()
  let assert Ok(client) = http_gun.start(local_config())
  let ready = process.new_subject()
  let result = process.new_subject()
  let creator =
    process.spawn_unlinked(fn() {
      let _ =
        cancellation.with_token(fn(token) {
          process.send(ready, token)
          process.sleep_forever()
        })
      Nil
    })
  let assert Ok(token) = process.receive(ready, 1000)
  let options =
    request_options.Options(
      ..request_options.default(),
      cancellation: Some(token),
    )
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        result,
        http_gun.send_with_options(client, req(port), options),
      )
    })
  await_request(server)
  process.kill(creator)
  let assert Ok(Error(failure)) = process.receive(result, 1000)
  failure |> should.equal(error.Failure(error.Cancelled, error.MayHaveBeenSent))
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

pub fn completed_http_survives_later_cancellation_test() {
  let req = req(80)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.new(204) |> response.set_body([]),
        fixture.Complete([#("x-end", "yes")]),
      ),
    )
  let assert Ok(client) = testing.start(local_config(), [exchange])
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          cancellation: Some(token),
        )
      let assert Ok(response) = http_gun.open_with_options(client, req, options)
      body.next(response.body, 1000)
      |> should.equal(Ok(body.End([#("x-end", "yes")])))
      cancellation.cancel(token)
      body.next(response.body, 1000)
      |> should.equal(Ok(body.End([#("x-end", "yes")])))
      let _ = body.close(response.body)
      Nil
    })
  let _ = http_gun.stop(client)
}

pub fn last_queued_cancellation_releases_shared_connecting_socket_test() {
  let #(port, server) = gated()
  let c = local_config()
  let assert Ok(client) = http_gun.start(config.Config(..c, connect_ms: 5000))
  let results = process.new_subject()
  let request = req(port) |> request.set_scheme(http.Https)
  let assert Ok(Ok(Nil)) =
    cancellation.with_token(fn(first) {
      cancellation.with_token(fn(second) {
        let first_options =
          request_options.Options(
            ..request_options.default(),
            cancellation: Some(first),
          )
        let second_options =
          request_options.Options(
            ..request_options.default(),
            cancellation: Some(second),
          )
        let _ =
          process.spawn_unlinked(fn() {
            process.send(
              results,
              http_gun.send_with_options(client, request, first_options),
            )
          })
        await_request(server)
        let _ =
          process.spawn_unlinked(fn() {
            process.send(
              results,
              http_gun.send_with_options(client, request, second_options),
            )
          })
        wait_for_queue(client, 1, 1000) |> should.be_true
        cancellation.cancel(first)
        let assert Ok(Error(failure)) = process.receive(results, 1000)
        failure
        |> should.equal(error.Failure(error.Cancelled, error.NotSubmitted))
        let assert Ok(stats) = http_gun.snapshot(client)
        stats.connections |> should.equal(1)
        cancellation.cancel(second)
        let assert Ok(Error(failure)) = process.receive(results, 1000)
        failure
        |> should.equal(error.Failure(error.Cancelled, error.NotSubmitted))
        let assert Ok(stats) = http_gun.snapshot(client)
        stats.connections |> should.equal(0)
      })
    })
  let _ = http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
