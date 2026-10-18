//// Configure a client: start from the default, set only what differs, and let
//// validation refuse an out-of-range value before anything starts.

import gleam/http/request
import gleam/int
import gleam/time/duration
import http_gun
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

pub fn main() -> Nil {
  // A Config is opaque: start from `config.default()` and set only what you need.
  let settings =
    config.default()
    |> config.with_protocol(config.PreferHttp2)
    |> config.with_connect_timeout(duration.seconds(3))
    |> config.with_request_timeout(config.After(duration.seconds(10)))
    |> config.with_max_response_body_bytes(1_048_576)
  let assert Ok(_) = config.validate(settings)

  // Lifting the request or idle timeout is explicit.
  let assert Ok(_) =
    config.default()
    |> config.with_request_timeout(config.Infinity)
    |> config.with_idle_timeout(config.Infinity)
    |> config.validate

  // An out-of-range value is refused with a typed error, without a start.
  let assert Error(http_gun.InvalidConfig(config.OutOfRange(
    config.MaxOpenBodies,
    0,
  ))) =
    config.default()
    |> config.with_max_open_bodies(0)
    |> http_gun.start

  // The default admits public destinations only: a local server is refused
  // before any connection opens, until loopback is allowed explicitly.
  let req = local_request(server())
  let assert Ok(public_only) = http_gun.start(config.default())
  let assert Error(refused) = http_gun.send(public_only, req)
  let assert error.Refused = error.kind(refused)
  let assert error.NotSent = error.evidence(refused)
  http_gun.stop(public_only)

  let assert Ok(local) =
    config.default() |> config.allow_loopback |> http_gun.start
  let assert Ok(_) = http_gun.send(local, req)
  http_gun.stop(local)
}

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://localhost:" <> int.to_string(port))
  request.set_body(req, <<>>)
}
