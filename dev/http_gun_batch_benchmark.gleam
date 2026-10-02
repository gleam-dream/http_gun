import gleam/http/request
import gleam/int
import gleam/io
import gleam/list
import http_gun
import http_gun/config

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

@external(erlang, "http_gun_measure_ffi", "reductions")
fn reductions() -> Int

fn run(
  client: http_gun.Client,
  req: request.Request(BitArray),
  count: Int,
) -> Nil {
  let inputs = list.repeat(req, count)
  let before = reductions()
  let start = now()
  let assert Ok(results) = http_gun.batch(client, inputs, 4)
  let elapsed = now() - start
  let work = reductions() - before
  let assert True = list.length(results) == count
  list.each(results, fn(result) {
    let assert Ok(value) = result
    let assert <<"abc":utf8>> = value.response.body
  })
  io.println(
    "{\"requests\":"
    <> int.to_string(count)
    <> ",\"elapsed_us\":"
    <> int.to_string(elapsed)
    <> ",\"reductions\":"
    <> int.to_string(work)
    <> "}",
  )
}

pub fn main() -> Nil {
  let defaults = local_config()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..defaults,
        deadline_ms: 60_000,
        limits: config.Limits(..defaults.limits, connections: 4, per_origin: 4),
      ),
    )
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(server()) <> "/")
  let req = request.set_body(req, <<>>)
  run(client, req, 100)
  list.each([500, 1000, 2000, 5000, 10_000], fn(count) {
    run(client, req, count)
  })
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
