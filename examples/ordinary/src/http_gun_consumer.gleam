//// An ordinary application using HTTP Gun from its own package: the common
//// request first, then client views, a supervised client, failure handling,
//// observations and record/replay.

import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import gleam/time/duration
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/destination
import http_gun/error
import http_gun/telemetry
import http_gun/testing
import sinal
import sinal/correlation
import sinal/forwarder

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_test_server", "gated")
fn gated() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn arrived(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "unused_port")
fn unused_port() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

pub fn main() {
  let req = local_request(server())
  // The common path: start a client, send, read the collected response, stop.
  let assert Ok(client) = http_gun.start(local_config())
  let assert Ok(reply) = http_gun.send(client, req)
  let assert 200 = reply.response.status
  let assert <<"abc":utf8>> = reply.response.body
  http_gun.stop(client)

  supervised(req)
  failures(req)
  observed(req)
  record_and_replay(req)
}

// The application's own error type; `with_response` maps an opening failure
// into it, so the callback and the call share one `Result` type.
type FetchError {
  Http(error.Failure)
  UnexpectedStatus(Int)
}

// This consumer is unchanged across live, recording and playback clients.
fn consume(client: http_gun.Client, req: request.Request(BitArray)) -> Nil {
  let assert Ok(reply) = http_gun.send(client, req)
  let assert <<"abc":utf8>> = reply.response.body
  // Per-call settings are views of the same client: a 5 s budget shared by
  // every request made through it, and a token that cancels them.
  let budget = deadline.after(duration.seconds(5))
  let assert Ok(<<"abc":utf8>>) = {
    use token <- cancellation.with_token
    client
    |> http_gun.with_deadline(budget)
    |> http_gun.with_cancellation(token)
    |> first_chunk(req)
  }
  let assert Ok(results) = http_gun.batch(client, list.repeat(req, 10), 3)
  let assert True = list.all(results, result.is_ok)
  Nil
}

fn first_chunk(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(BitArray, FetchError) {
  use response <- http_gun.with_response(client, req, Http)
  case response.status {
    // Returning after the first chunk is an ordinary early stop: the body is
    // closed when the callback returns.
    200 ->
      case body.next(response.body) {
        Ok(body.Chunk(bytes)) -> Ok(bytes)
        Ok(body.End(_)) -> Ok(<<>>)
        Error(failure) -> Error(Http(failure))
      }
    status -> Error(UnexpectedStatus(status))
  }
}

// Under a supervisor, the client registers under a name and `named` returns
// a handle that keeps working across restarts.
fn supervised(req: request.Request(BitArray)) -> Nil {
  let name = process.new_name("http_client")
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(local_config(), name))
    |> static_supervisor.start
  let client = http_gun.named(name)
  consume(client, req)
}

// Branch on the closed `Kind`, and ask `is_retryable` whether sending the
// request again is safe. HTTP Gun never retries on its own.
fn failures(req: request.Request(BitArray)) -> Nil {
  let assert Ok(client) = http_gun.start(local_config())

  // A view can only narrow the destinations its client admits.
  let pinned =
    client
    |> http_gun.with_destination(
      destination.loopback_only() |> destination.only_hosts(["127.0.0.1"]),
    )
  let assert Error(refused) = http_gun.send(pinned, req)
  let assert error.Refused = error.kind(refused)
  let assert error.DestinationRejected(destination.HostNotAllowed) =
    error.reason(refused)
  let assert False = error.is_retryable(refused, idempotent: True)

  // Nothing listens on this port: the request never left, so a retry is safe
  // even for a request that is not idempotent.
  let assert Error(unreachable) =
    http_gun.send(client, local_request(unused_port()))
  let assert error.Network = error.kind(unreachable)
  let assert error.NotSent = error.evidence(unreachable)
  let assert True = error.is_retryable(unreachable, idempotent: False)

  // The server received the request but sends no response within 200 ms. It
  // may have acted on it, so only an idempotent request is retried.
  let #(port, peer) = gated()
  let slow =
    client |> http_gun.with_timeout(config.After(duration.milliseconds(200)))
  let assert Error(timed_out) = http_gun.send(slow, local_request(port))
  arrived(peer)
  let assert error.TimedOut = error.kind(timed_out)
  let assert error.MaybeSent = error.evidence(timed_out)
  let assert True = error.is_retryable(timed_out, idempotent: True)
  let assert False = error.is_retryable(timed_out, idempotent: False)

  // A body over the view's limit fails with the status it belonged to, or
  // is cut at the limit on request.
  let assert Error(too_large) =
    http_gun.send(client |> http_gun.with_body_limit(2, http_gun.Fail), req)
  let assert error.TooLarge = error.kind(too_large)
  let assert Some(200) = error.status(too_large)
  let assert Ok(cut) =
    http_gun.send(client |> http_gun.with_body_limit(2, http_gun.Truncate), req)
  let assert True = cut.truncated
  let assert <<"ab":utf8>> = cut.response.body

  // A mapped failure keeps its detail for the application.
  let assert Error(Http(mapped)) = first_chunk(pinned, req)
  let assert "destination_rejected.host_not_allowed" = error.name(mapped)
  http_gun.stop(client)
}

// Application startup owns the forwarder and routes HTTP Gun's events to it
// once, so handlers never run in the client's pool or body processes.
fn observed(req: request.Request(BitArray)) -> Nil {
  let target =
    forwarder.new(process.new_name("http-observations"))
    |> forwarder.with_capacity(64)
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(target))
    |> static_supervisor.start
  forwarder.route(["http_gun"], target)
  let completed = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      case metadata.milestone {
        telemetry.HttpTerminated(telemetry.Complete) ->
          process.send(completed, #(time, metadata))
        _ -> Nil
      }
    })
  let assert Ok(shared) = http_gun.start(local_config())
  // The application's own id for this unit of work; every gleam-dream
  // package writes it under the same `correlation` metadata key.
  let assert Ok(correlation) = correlation.from_string("order-42")
  let client = http_gun.with_correlation(shared, correlation)
  let assert Ok(_) = http_gun.send(client, req)
  let assert Ok(#(_, metadata)) = process.receive(completed, 1000)
  let assert True = metadata.correlation == Some(correlation)
  let assert telemetry.Live = metadata.mode
  let assert Ok(Nil) = sinal.detach(attachment)
  forwarder.unroute(["http_gun"])
  http_gun.stop(shared)
  // The application supervisor lives until this executable exits; individual
  // request/client completion does not stop its shared observation service.
  Nil
}

// Record against the live server once, then replay the cassette offline with
// the same consumer code.
fn record_and_replay(req: request.Request(BitArray)) -> Nil {
  let path = temp_path()
  let assert Ok(cassette.Recorded(client:, recording:)) =
    cassette.record(local_config(), path, cassette.options())
  consume(client, req)
  let assert Ok(saved) = cassette.finish(recording, duration.seconds(5))
  let assert True = path == saved
  http_gun.stop(client)
  let assert Ok(script) = cassette.load(path, 1_000_000)
  let assert Ok(playback) = testing.playback(script, local_config())
  consume(playback, req)
  http_gun.stop(playback)
  remove_fixture(path)
}

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://localhost:" <> int.to_string(port))
  request.set_body(req, <<>>)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
