//// A schema 3 cassette reads back every request target a live client
//// accepts, exactly, so replay matches the request that was recorded.

import gleam/http
import gleam/http/request
import gleam/option.{Some}
import gleam/time/duration
import gleeunit/should
import http_gun
import http_gun/cassette
import http_gun/config
import http_gun/testing
import simplifile

@external(erlang, "http_gun_test_server", "serve")
fn serve(response: BitArray) -> Int

@external(erlang, "http_gun_destination_test_ffi", "echo_authority")
fn echo_authority(ipv6: Bool) -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

fn settings() -> config.Config {
  config.default()
  |> config.with_request_timeout(config.After(duration.milliseconds(1000)))
  |> config.allow_loopback
}

fn target(host: String, port: Int) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host(host)
  |> request.set_port(port)
  |> request.set_path("/")
  |> request.set_body(<<>>)
}

fn ok() -> Int {
  serve(<<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\nok":utf8>>)
}

fn round_trip(sent: request.Request(BitArray)) -> Nil {
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings(), destination, cassette.options())
  let assert Ok(live) = http_gun.send(recorded.client, sent)
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)

  let assert Ok(text) = simplifile.read(destination)
  cassette.upgrade(text, 1_000_000) |> should.equal(Ok(text))
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored) |> should.equal(sent)

  let assert Ok(client) = testing.playback(tape, settings())
  let assert Ok(replayed) = http_gun.send(client, sent)
  replayed.response.body |> should.equal(live.response.body)
  testing.verify(client) |> should.equal(Ok(testing.Verdict([], [], [], 0)))
  http_gun.stop(client)
  remove(destination)
}

pub fn query_with_reserved_characters_round_trips_test() {
  round_trip(
    request.Request(
      ..target("127.0.0.1", ok()),
      path: "/items",
      query: Some("filter[status]=open&a={b}|c\"d<e>f\\g^h`i"),
    ),
  )
}

pub fn non_ascii_path_round_trips_test() {
  round_trip(target("127.0.0.1", ok()) |> request.set_path("/ação/日本"))
}

pub fn control_character_in_query_round_trips_test() {
  round_trip(
    request.Request(
      ..target("127.0.0.1", ok()),
      path: "/c",
      query: Some("a=\u{1}b"),
    ),
  )
}

pub fn question_mark_in_path_round_trips_test() {
  round_trip(target("127.0.0.1", ok()) |> request.set_path("/a?b"))
}

pub fn hash_in_path_round_trips_test() {
  round_trip(target("127.0.0.1", ok()) |> request.set_path("/a#b"))
}

pub fn bare_ipv6_host_round_trips_test() {
  round_trip(target("::1", echo_authority(True)))
}

pub fn bracketed_ipv6_host_round_trips_test() {
  round_trip(target("[::1]", echo_authority(True)))
}

// A method spelled as Other("GET") is the same method as Get: it is
// recorded as Get and its live form still replays.
pub fn other_spelling_of_a_known_method_replays_test() {
  let sent = target("127.0.0.1", ok()) |> request.set_method(http.Other("GET"))
  let destination = path()
  let assert Ok(recorded) =
    cassette.record(settings(), destination, cassette.options())
  let assert Ok(_) = http_gun.send(recorded.client, sent)
  let assert Ok(_) =
    cassette.finish(recorded.recording, duration.milliseconds(1000))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 1_000_000)
  let assert [stored] = testing.exchanges(tape)
  testing.request(stored).method |> should.equal(http.Get)
  let assert Ok(client) = testing.playback(tape, settings())
  let assert Ok(_) = http_gun.send(client, sent)
  testing.verify(client) |> should.equal(Ok(testing.Verdict([], [], [], 0)))
  http_gun.stop(client)
  remove(destination)
}
