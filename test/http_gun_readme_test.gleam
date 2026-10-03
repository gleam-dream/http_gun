//// The README's examples, compiled and run against local servers.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{Some}
import gleam/otp/static_supervisor
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/redaction
import http_gun/testing
import sinal/correlation

@external(erlang, "http_gun_test_server", "persistent")
fn persistent() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

fn local(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://127.0.0.1:" <> int.to_string(port) <> "/data")
  request.set_body(req, <<>>)
}

pub fn send_a_request_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)
  let result = http_gun.send(client, local(port))
  http_gun.stop(client)
  let assert Ok(buffered) = result
  buffered.response.body |> should.equal(<<"abc">>)
}

pub fn configure_test() {
  let settings =
    config.default()
    |> config.with_protocol(config.PreferHttp2)
    |> config.with_request_timeout(config.Milliseconds(10_000))
    |> config.with_max_response_body_bytes(1_048_576)
  config.validate(settings) |> should.be_ok
  config.default()
  |> config.with_max_open_bodies(0)
  |> http_gun.start
  |> should.equal(
    Error(http_gun.InvalidConfig(config.OutOfRange(config.MaxOpenBodies, 0))),
  )
}

pub fn client_views_and_streaming_test() {
  let port = persistent()
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)
  let order = correlation.unique()
  let stream =
    client
    |> http_gun.with_timeout(config.Infinity)
    |> http_gun.with_idle_timeout(config.Milliseconds(60_000))
    |> http_gun.with_correlation(order)
  let counted = {
    use response <- http_gun.with_response(stream, local(port), fn(failure) {
      failure
    })
    count(response.body, 0)
  }
  counted |> should.equal(Ok(3))
  http_gun.stop(client)
}

fn count(stream: body.Body, total: Int) -> Result(Int, error.Failure) {
  case body.next(stream) {
    Ok(body.Chunk(bytes)) -> count(stream, total + bit_array.byte_size(bytes))
    Ok(body.End(..)) -> Ok(total)
    Error(failure) -> Error(failure)
  }
}

type Outcome {
  BadDestination
  TooBig(option.Option(Int))
  TryLater
  Failed(String)
}

fn handle(
  result: Result(http_gun.Buffered, error.Failure),
) -> Result(response.Response(BitArray), Outcome) {
  case result {
    Ok(buffered) -> Ok(buffered.response)
    Error(failure) ->
      case error.kind(failure) {
        error.Refused -> Error(BadDestination)
        error.TooLarge -> Error(TooBig(error.status(failure)))
        _ ->
          case error.is_retryable(failure, idempotent: False) {
            True -> Error(TryLater)
            False -> Error(Failed(error.describe(failure)))
          }
      }
  }
}

pub fn handle_failures_test() {
  let port = persistent()
  let assert Ok(public_only) = http_gun.start(config.default())
  handle(http_gun.send(public_only, local(port)))
  |> should.equal(Error(BadDestination))
  http_gun.stop(public_only)
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.allow_loopback
      |> config.with_max_response_body_bytes(2),
    )
  handle(http_gun.send(client, local(port)))
  |> should.equal(Error(TooBig(Some(200))))
  http_gun.stop(client)
}

pub fn destination_setups_test() {
  let port = persistent()
  let public_and_loopback = config.default() |> config.allow_loopback
  let loopback_only =
    config.default() |> config.with_destination(destination.loopback_only())
  let pinned =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
    )
  [public_and_loopback, loopback_only, pinned]
  |> list_each(fn(settings) {
    let assert Ok(client) = http_gun.start(settings)
    http_gun.send(client, local(port)) |> should.be_ok
    http_gun.stop(client)
  })
  let assert Ok(client) = http_gun.start(pinned)
  let assert Error(failure) = http_gun.send(client, local(port + 1))
  error.reason(failure)
  |> should.equal(error.DestinationRejected(destination.HostNotAllowed))
  http_gun.stop(client)
}

fn list_each(items: List(a), run: fn(a) -> Nil) -> Nil {
  case items {
    [] -> Nil
    [item, ..rest] -> {
      run(item)
      list_each(rest, run)
    }
  }
}

pub fn supervision_test() {
  let port = persistent()
  let name = process.new_name("http_client")
  let assert Ok(_) =
    static_supervisor.new(static_supervisor.OneForOne)
    |> static_supervisor.add(http_gun.supervised(
      config.default() |> config.allow_loopback,
      name,
    ))
    |> static_supervisor.start
  let client = http_gun.named(name)
  http_gun.send(client, local(port)) |> should.be_ok
}

pub fn test_without_a_network_test() {
  let req = local(1)
  let script =
    testing.script([
      testing.exchange(
        req,
        testing.Respond(
          response.new(200) |> response.set_body([<<"{\"ok\":true}">>]),
          testing.Finished([]),
        ),
      ),
    ])
  let assert Ok(client) = testing.playback(script, config.default())
  let assert Ok(buffered) = http_gun.send(client, req)
  buffered.response.body |> should.equal(<<"{\"ok\":true}">>)
  let assert Error(failure) = http_gun.send(client, req)
  error.reason(failure) |> should.equal(error.PlaybackExhausted)
  http_gun.stop(client)
}

pub fn record_then_replay_with_redaction_test() {
  let port = persistent()
  let path = temp_path()
  let redaction =
    redaction.default()
    |> redaction.with_headers(["x-signature"])
    |> redaction.with_query_parameters(["token"])
  let settings =
    config.default()
    |> config.allow_loopback
    |> config.with_redaction(redaction)
  let req =
    local(port)
    |> request.set_query([#("token", "secret-value"), #("page", "2")])
    |> request.set_header("x-signature", "secret-signature")
  let assert Ok(cassette.Recorded(client:, recording:)) =
    cassette.record(settings, path, cassette.options())
  let _ = http_gun.send(client, req)
  let assert Ok(_) = cassette.finish(recording, 5000)
  http_gun.stop(client)

  let assert Ok(script) = cassette.load(path, 1_048_576)
  let encoded = cassette.encode(script)
  remove_fixture(path)
  let assert Ok(replay) = testing.playback(script, settings)
  let assert Ok(buffered) = http_gun.send(replay, req)
  buffered.response.body |> should.equal(<<"abc">>)
  http_gun.stop(replay)
  string.contains(encoded, "secret") |> should.be_false
  string.contains(encoded, "token=REDACTED&page=2") |> should.be_true
}

type Tier {
  PublicTier
  InternalTier(hosts: List(String))
}

fn for_tenant(client: http_gun.Client, tier: Tier) -> http_gun.Client {
  case tier {
    PublicTier -> client |> http_gun.with_destination(destination.default())
    InternalTier(hosts) ->
      client
      |> http_gun.with_destination(
        destination.loopback_only() |> destination.only_hosts(hosts),
      )
  }
}

pub fn one_client_for_several_tenants_test() {
  let port = persistent()
  let assert Ok(client) =
    config.default()
    |> config.allow_loopback
    |> config.require_view_destination
    |> http_gun.start
  let internal = InternalTier(["127.0.0.1:" <> int.to_string(port)])
  let assert Ok(buffered) =
    for_tenant(client, internal) |> http_gun.send(local(port))
  buffered.response.body |> should.equal(<<"abc">>)
  let assert Error(failure) =
    for_tenant(client, PublicTier) |> http_gun.send(local(port))
  error.reason(failure)
  |> should.equal(
    error.DestinationRejected(destination.AddressRefused(destination.Loopback)),
  )
  let assert Error(failure) = http_gun.send(client, local(port))
  error.reason(failure) |> should.equal(error.ViewDestinationRequired)
  http_gun.stop(client)
}

pub fn failure_keeps_retry_after_test() {
  let req = request.new() |> request.set_body(<<>>)
  let reply =
    response.new(429)
    |> response.set_header("retry-after", "30")
    |> response.set_body([<<"too large":utf8>>])
  let assert Ok(client) =
    testing.playback(
      testing.script([
        testing.exchange(req, testing.Respond(reply, testing.Finished([]))),
      ]),
      config.default(),
    )
  let assert Error(failure) =
    http_gun.send(client |> http_gun.with_body_limit(4, http_gun.Fail), req)
  let decision = case
    error.status(failure),
    list.key_find(error.headers(failure), "retry-after")
  {
    Some(429), Ok(seconds) -> Ok(seconds)
    _, _ -> Error(failure)
  }
  decision |> should.equal(Ok("30"))
  http_gun.stop(client)
}
