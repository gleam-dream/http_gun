//// Finite concurrent recording pressure and byte-exact offline replay.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import http_gun
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/recording

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_test_server", "temp_path")
fn path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

@external(erlang, "http_gun_measure_ffi", "sampler")
fn sampler() -> process.Pid

@external(erlang, "http_gun_measure_ffi", "finish")
fn measured(pid: process.Pid) -> #(Int, Int, Int, Int, Int)

fn finish(
  rec: recording.Recording,
  attempts: Int,
) -> Result(String, recording.FinishError) {
  case cassette.finish(rec) {
    Error(recording.Busy) if attempts > 0 -> finish(rec, attempts - 1)
    other -> other
  }
}

pub fn main() -> Nil {
  let port = server()
  let destination = path()
  let bytes =
    int.range(0, 256, <<>>, fn(acc, byte) { <<acc:bits, byte>> })
    |> list.repeat(64)
    |> bit_array.concat
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  let req = req |> request.set_method(http.Post) |> request.set_body(bytes)
  let inputs = list.repeat(req, 256)
  let c = local_config()
  let settings =
    config.Config(
      ..c,
      deadline_ms: 60_000,
      limits: config.Limits(..c.limits, connections: 4, per_origin: 4),
    )
  let assert Ok(recorded) =
    cassette.record(settings, destination, recording.default())
  let sample = sampler()
  let start = now()
  let assert Ok(replies) = http_gun.batch(recorded.client, inputs, 16)
  list.each(replies, fn(reply) {
    let assert Ok(reply) = reply
    let assert True = reply.response.body == bytes
  })
  let assert Ok(_) = finish(recorded.recording, 10_000)
  let elapsed = now() - start
  let stats = measured(sample)
  let assert Ok(empty) = http_gun.snapshot(recorded.client)
  let assert 0 = empty.bodies
  let assert 0 = empty.waiting
  let assert True = empty.connections <= 4
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(destination, 16_777_216)
  let assert Ok(playback) = cassette.playback(tape, settings)
  let assert Ok(replayed) = http_gun.batch(playback, inputs, 16)
  list.each(replayed, fn(reply) {
    let assert Ok(reply) = reply
    let assert config.Offline = reply.protocol
    let assert True = reply.response.body == bytes
  })
  let assert Ok(Nil) = http_gun.stop(playback)
  remove(destination)
  io.println(
    json.object([
      #("scenario", json.string("record-and-replay")),
      #("requests", json.int(256)),
      #("workers", json.int(16)),
      #("connections", json.int(empty.connections)),
      #("request_and_response_bytes", json.int(8_388_608)),
      #("capture_and_finish_us", json.int(elapsed)),
      #("peak_vm_bytes", json.int(stats.0)),
      #("peak_total_mailbox", json.int(stats.1)),
      #("peak_one_mailbox", json.int(stats.2)),
      #("peak_processes", json.int(stats.3)),
      #("peak_ports", json.int(stats.4)),
    ])
    |> json.to_string,
  )
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  let defaults = config.default()
  config.Config(
    ..defaults,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
    ),
  )
}
