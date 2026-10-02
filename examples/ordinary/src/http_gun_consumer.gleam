import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/result
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/recording
import http_gun/request_options
import http_gun/telemetry
import sinal
import sinal/correlation
import sinal/forwarder

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

// This consumer is unchanged across live, recording and playback clients.
fn consume(client: http_gun.Client, req: request.Request(BitArray)) {
  let assert Ok(reply) = http_gun.send(client, req)
  let assert 200 = reply.response.status
  let assert <<"abc":utf8>> = reply.response.body
  let assert Ok(budget) = deadline.after(5000)
  let assert Ok(Ok(_)) =
    cancellation.with_token(fn(token) {
      let options =
        request_options.Options(
          ..request_options.default(),
          deadline: Some(budget),
          cancellation: Some(token),
        )
      http_gun.try_with_response_with_options(
        client,
        req,
        options,
        fn(e) { e },
        fn(response) {
          // Returning after the first chunk is an ordinary early termination.
          body.next(response.body, 1000)
        },
      )
    })
  let assert Ok(results) = http_gun.batch(client, list.repeat(req, 10), 3)
  let assert True = list.all(results, result.is_ok)
}

pub fn main() {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(server()))
  let req = request.set_body(req, <<>>)
  observed_request(req)
  let assert Ok(live) = http_gun.start(local_config())
  consume(live, req)
  let assert Ok(Nil) = http_gun.stop(live)
  let path = temp_path()
  let assert Ok(recorded) =
    cassette.record(local_config(), path, recording.default())
  consume(recorded.client, req)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  let assert Ok(saved) = recording.finish_wait(recorded.recording, 5000)
  let assert True = path == saved
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(playback) = cassette.playback(tape, local_config())
  consume(playback, req)
  let assert Ok(Nil) = http_gun.stop(playback)
  remove_fixture(path)
}

// Application startup owns the forwarder and its supervision. The HTTP client
// emits fixed milestones; a handler does not run in its pool or body processes.
fn observed_request(req: request.Request(BitArray)) -> Nil {
  let target =
    forwarder.new(process.new_name("http-observations"))
    |> forwarder.with_capacity(64)
  let assert Ok(_supervisor) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(forwarder.supervised(target))
    |> static_supervisor.start
  let completed = process.new_subject()
  let attachment =
    sinal.observe(telemetry.event(), fn(time, metadata) {
      case metadata.milestone {
        telemetry.HttpTerminated(telemetry.Complete) ->
          process.send(completed, #(time, metadata))
        _ -> Nil
      }
    })
  let settings = config.Config(..local_config(), observations: Some(target))
  let assert Ok(shared) = http_gun.start(settings)
  // The application's own id for this unit of work; every gleam-dream
  // package writes it under the same `correlation` metadata key.
  let assert Ok(correlation) = correlation.from_string("order-42")
  let client = http_gun.with_correlation(shared, correlation)
  let assert Ok(_) = http_gun.send(client, req)
  let assert Ok(#(_, metadata)) = process.receive(completed, 1000)
  let assert True = metadata.correlation == Some(correlation)
  let assert telemetry.Live = metadata.mode
  let assert Ok(Nil) = sinal.detach(attachment)
  let assert Ok(Nil) = http_gun.stop(shared)
  // The application supervisor lives until this executable exits; individual
  // request/client completion does not stop its shared observation service.
  Nil
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
