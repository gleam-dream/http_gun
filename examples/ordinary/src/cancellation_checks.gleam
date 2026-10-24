//// Separate-consumer checks for independent cancellation authorities.

import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/time/duration
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/testing

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn arrived(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

pub fn main() -> Nil {
  before_submission(True)
  before_submission(False)
  replacement()
  queued(True)
  queued(False)
  streaming(True)
  streaming(False)
}

fn before_submission(cancel_application: Bool) -> Nil {
  use application <- cancellation.with_token
  use operation <- cancellation.with_token
  let assert Ok(req) = request.to("https://example.test/value")
  let req = request.set_body(req, <<>>)
  let assert Ok(client) =
    testing.playback(
      testing.script([
        testing.exchange(
          req,
          testing.Respond(
            response.new(200) |> response.set_body([<<"ok":utf8>>]),
            testing.Finished([]),
          ),
        ),
      ]),
      config.default(),
    )
  let view =
    client
    |> http_gun.with_cancellation(application)
    |> http_gun.with_additional_cancellation(operation)
    |> http_gun.with_additional_cancellation(operation)
  cancel_one(application, operation, cancel_application)
  let assert Error(failure) = http_gun.send(view, req)
  let assert error.Cancelled = error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert Ok(reply) = http_gun.send(client, req)
  let assert <<"ok":utf8>> = reply.response.body
  http_gun.stop(client)
}

fn replacement() -> Nil {
  use application <- cancellation.with_token
  use operation <- cancellation.with_token
  use replacement <- cancellation.with_token
  let assert Ok(client) = http_gun.start(local_config())
  let original =
    client
    |> http_gun.with_cancellation(application)
    |> http_gun.with_additional_cancellation(operation)
  let replaced = http_gun.with_cancellation(original, replacement)
  cancellation.cancel(application)
  cancellation.cancel(operation)
  let req = local_request(server())
  let assert Ok(_) = http_gun.send(replaced, req)
  let assert Error(failure) = http_gun.send(original, req)
  let assert error.NotSent = error.evidence(failure)
  let assert False = cancellation.is_cancelled(replacement)
  http_gun.stop(client)
}

fn queued(cancel_application: Bool) -> Nil {
  use application <- cancellation.with_token
  use operation <- cancellation.with_token
  let assert Ok(client) =
    http_gun.start(local_config() |> config.with_max_open_bodies(1))
  let req = local_request(server())
  let assert Ok(held) = http_gun.open(client, req)
  let view =
    client
    |> http_gun.with_cancellation(application)
    |> http_gun.with_additional_cancellation(operation)
    |> http_gun.with_additional_cancellation(operation)
  let result = process.new_subject()
  let _ = process.spawn(fn() { process.send(result, http_gun.send(view, req)) })
  await_counts(client, 1, 1, 200)
  cancel_one(application, operation, cancel_application)
  let assert Ok(Error(failure)) = process.receive(result, 2000)
  let assert error.Cancelled = error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  await_counts(client, 1, 0, 200)
  body.close(held.body)
  await_counts(client, 0, 0, 200)
  let assert Ok(_) = http_gun.send(client, req)
  http_gun.stop(client)
}

fn streaming(cancel_application: Bool) -> Nil {
  use application <- cancellation.with_token
  use operation <- cancellation.with_token
  let assert Ok(client) = http_gun.start(local_config())
  let #(port, peer) = controlled()
  let view =
    client
    |> http_gun.with_cancellation(application)
    |> http_gun.with_additional_cancellation(operation)
    |> http_gun.with_additional_cancellation(operation)
  let assert Ok(response) = http_gun.open(view, local_request(port))
  arrived(peer)
  cancel_one(application, operation, cancel_application)
  let assert Error(failure) = body.next(response.body)
  let assert error.Cancelled = error.reason(failure)
  let assert error.MaybeSent = error.evidence(failure)
  let assert True = closed(peer)
  body.close(response.body)
  await_counts(client, 0, 0, 200)
  let assert Ok(_) = http_gun.send(client, local_request(server()))
  http_gun.stop(client)
}

fn cancel_one(
  application: cancellation.Token,
  operation: cancellation.Token,
  cancel_application: Bool,
) -> Nil {
  let #(selected, retained) = case cancel_application {
    True -> #(application, operation)
    False -> #(operation, application)
  }
  cancellation.cancel(selected)
  let assert False = cancellation.is_cancelled(retained)
  Nil
}

fn local_config() -> config.Config {
  config.default()
  |> config.with_destination(destination.loopback_only())
  |> config.with_request_timeout(config.After(duration.seconds(5)))
}

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn await_counts(
  client: http_gun.Client,
  bodies: Int,
  queued: Int,
  attempts: Int,
) -> Nil {
  let assert Ok(stats) = http_gun.stats(client)
  case stats.open_bodies == bodies && stats.queued_requests == queued {
    True -> Nil
    False -> {
      let assert True = attempts > 0
      process.sleep(10)
      await_counts(client, bodies, queued, attempts - 1)
    }
  }
}
