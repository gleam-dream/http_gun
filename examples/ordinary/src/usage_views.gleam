//// Per-call settings as client views, streamed bodies and ordered batches.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error
import sinal/correlation

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

pub fn main() -> Nil {
  let req = local_request(server())
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)

  // Each view returns a new handle over the same pool.
  let order = correlation.unique()
  let stream =
    client
    |> http_gun.with_timeout(config.Infinity)
    |> http_gun.with_idle_timeout(config.After(duration.seconds(60)))
    |> http_gun.with_correlation(order)
  let assert Some(read_back) = http_gun.correlation(stream)
  let assert True = read_back == order
  let assert None = http_gun.correlation(client)

  // `with_response` closes the body when the callback returns or raises.
  let assert Ok(3) = {
    use response <- http_gun.with_response(stream, req, fn(failure) { failure })
    count(response.body, 0)
  }

  // A body read with a wait returns `None` when nothing arrived in time and
  // leaves the stream intact; here the bytes are already there.
  let assert Ok(response) = http_gun.open(client, req)
  let assert Ok(Some(body.Chunk(<<"abc":utf8>>))) =
    body.next_within(response.body, duration.seconds(1))
  let assert Ok(body.End(..)) = body.next(response.body)
  // Closing is idempotent, and is required even after the end.
  body.close(response.body)
  body.close(response.body)

  // The opening process owns the body: a read from another process fails.
  let assert Ok(shared) = http_gun.open(client, req)
  let result = process.new_subject()
  let _ = process.spawn(fn() { process.send(result, body.next(shared.body)) })
  let assert Ok(Error(foreign)) = process.receive(result, 1000)
  let assert error.WrongOwner = error.reason(foreign)
  body.close(shared.body)

  // A body over the view's limit fails with the status it belonged to, or is
  // cut at the limit on request.
  let assert Error(too_large) =
    http_gun.send(client |> http_gun.with_body_limit(2, http_gun.Fail), req)
  let assert error.TooLarge = error.kind(too_large)
  let assert Some(200) = error.status(too_large)
  let assert Ok(cut) =
    http_gun.send(client |> http_gun.with_body_limit(2, http_gun.Truncate), req)
  let assert True = cut.truncated
  let assert <<"ab":utf8>> = cut.response.body

  // `batch` runs at most `concurrency` requests at once and keeps input order.
  let assert Ok(results) = http_gun.batch(client, list.repeat(req, 6), 2)
  let assert 6 = list.length(results)
  let assert True = list.all(results, result.is_ok)
  http_gun.stop(client)
}

fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
  case body.next(stream) {
    Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(..)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://localhost:" <> int.to_string(port))
  request.set_body(req, <<>>)
}
