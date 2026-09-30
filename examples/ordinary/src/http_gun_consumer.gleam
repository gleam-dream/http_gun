import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/result
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/deadline
import http_gun/recording
import http_gun/request_options

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
      let options = request_options.Options(Some(budget), Some(token))
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
  let assert Ok(live) = http_gun.start(config.default())
  consume(live, req)
  let assert Ok(Nil) = http_gun.stop(live)
  let path = temp_path()
  let assert Ok(recorded) =
    cassette.record(config.default(), path, recording.default())
  consume(recorded.client, req)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  let assert Ok(saved) = recording.finish_wait(recorded.recording, 5000)
  let assert True = path == saved
  let assert Ok(tape) = cassette.load(path, 1_000_000)
  let assert Ok(playback) = cassette.playback(tape, config.default())
  consume(playback, req)
  let assert Ok(Nil) = http_gun.stop(playback)
  remove_fixture(path)
}
