//// Cold-start latency: N concurrent requests to an origin the client has
//// never connected to, against a local TLS server that waits a fixed delay
//// before each handshake. Each run starts a new client, so every run is
//// cold. Prints one JSON line per run with the wall time until the last
//// response.
////
//// Run with `gleam run -m http_gun_cold_start_benchmark`.

import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import http_gun
import http_gun/config

@external(erlang, "http_gun_tls_test_server", "slow_handshake")
fn server(delay_ms: Int) -> Int

@external(erlang, "http_gun_tls_test_server", "anchors")
fn anchors(name: String) -> List(BitArray)

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

const delay_ms = 100

const runs = 5

pub fn main() -> Nil {
  let port = server(delay_ms)
  let assert Ok(req) = request.to("https://localhost:" <> int.to_string(port))
  let req = req |> request.set_scheme(http.Https) |> request.set_body(<<>>)
  list.each([1, 4, 8], fn(concurrency) {
    list.each(list.repeat(Nil, runs), fn(_) { run(req, concurrency) })
  })
}

fn run(req: request.Request(BitArray), concurrency: Int) -> Nil {
  let assert Ok(client) =
    config.default()
    |> config.allow_loopback
    |> config.with_trust(config.Anchors(anchors("ca")))
    |> config.with_max_connections(concurrency)
    |> config.with_max_connections_per_origin(concurrency)
    |> http_gun.start
  let done = process.new_subject()
  let start = now()
  list.each(list.repeat(Nil, concurrency), fn(_) {
    process.spawn(fn() { process.send(done, http_gun.send(client, req)) })
  })
  list.each(list.repeat(Nil, concurrency), fn(_) {
    let assert Ok(Ok(reply)) = process.receive(done, 30_000)
    let assert <<"abc":utf8>> = reply.response.body
  })
  let elapsed = now() - start
  let assert Ok(stats) = http_gun.stats(client)
  http_gun.stop(client)
  io.println(
    "{\"handshake_delay_ms\":"
    <> int.to_string(delay_ms)
    <> ",\"concurrency\":"
    <> int.to_string(concurrency)
    <> ",\"elapsed_us\":"
    <> int.to_string(elapsed)
    <> ",\"connections\":"
    <> int.to_string(stats.connections)
    <> "}",
  )
}
