import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import http_gun
import http_gun/body
import http_gun/config

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

@external(erlang, "http_gun_measure_ffi", "sampler")
fn sampler() -> process.Pid

@external(erlang, "http_gun_measure_ffi", "finish")
fn measured(pid: process.Pid) -> #(Int, Int, Int, Int, Int)

@external(erlang, "http_gun_measure_ffi", "pause")
fn pause(ms: Int) -> Nil

@external(erlang, "http_gun_measure_ffi", "large")
fn large(bytes: Int) -> Int

@external(erlang, "http_gun_test_server", "persistent")
fn h1() -> Int

@external(erlang, "http_gun_h2_server", "start")
fn h2() -> Int

fn req(port: Int, tls: Bool, path: String) -> request.Request(BitArray) {
  request.new()
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_scheme(case tls {
    True -> http.Https
    False -> http.Http
  })
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

fn settings(tls: Bool) -> config.Config {
  let c = config.default()
  config.Config(
    ..c,
    deadline_ms: 60_000,
    protocol: case tls {
      True -> config.RequireHttp2
      False -> config.Http1
    },
    trust: config.CustomCa("test/fixtures/ca.crt"),
    limits: config.Limits(
      ..c.limits,
      connections: case tls {
        True -> 1
        False -> 4
      },
      per_origin: 4,
      active: 128,
      waiting: 1024,
      streams_per_connection: 100,
    ),
  )
}

fn percentile(values: List(Int), numerator: Int) -> Int {
  list.drop(values, int.max(0, { list.length(values) * numerator / 100 } - 1))
  |> list.first
  |> result.unwrap(0)
}

fn emit(
  label: String,
  count: Int,
  elapsed: Int,
  times: List(Int),
  sockets: Int,
  sample: #(Int, Int, Int, Int, Int),
  bytes: Int,
) {
  let times = list.sort(times, int.compare)
  io.println(
    json.object([
      #("scenario", json.string(label)),
      #("requests", json.int(count)),
      #("elapsed_us", json.int(elapsed)),
      #("p50_us", json.int(percentile(times, 50))),
      #("p95_us", json.int(percentile(times, 95))),
      #("p99_us", json.int(percentile(times, 99))),
      #("connections", json.int(sockets)),
      #("peak_vm_bytes", json.int(sample.0)),
      #("peak_total_mailbox", json.int(sample.1)),
      #("peak_one_mailbox", json.int(sample.2)),
      #("peak_processes", json.int(sample.3)),
      #("peak_ports", json.int(sample.4)),
      #("bytes", json.int(bytes)),
    ])
    |> json.to_string,
  )
}

fn gather(
  subject: process.Subject(#(Int, String)),
  remaining: Int,
  values: List(#(Int, String)),
) {
  case remaining {
    0 -> values
    _ -> {
      let assert Ok(value) = process.receive(subject, 65_000)
      gather(subject, remaining - 1, [value, ..values])
    }
  }
}

fn concurrent(tls: Bool, count: Int) {
  let port = case tls {
    True -> h2()
    False -> h1()
  }
  let assert Ok(client) = http_gun.start(settings(tls))
  let sampler = sampler()
  let started = now()
  let done = process.new_subject()
  list.each(list.repeat(Nil, count), fn(_) {
    let _ =
      process.spawn(fn() {
        let started = now()
        let assert Ok(reply) = http_gun.send(client, req(port, tls, "/fast"))
        let assert Ok(socket) =
          response.get_header(reply.response, "x-connection")
        process.send(done, #(now() - started, socket))
      })
    Nil
  })
  let replies = gather(done, count, [])
  let elapsed = now() - started
  let sample = measured(sampler)
  let sockets = list.map(replies, fn(r) { r.1 }) |> list.unique |> list.length
  emit(
    case tls {
      True -> "h2-concurrent"
      False -> "h1-concurrent"
    },
    count,
    elapsed,
    list.map(replies, fn(r) { r.0 }),
    sockets,
    sample,
    count * 3,
  )
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn drain(body: body.Body, total: Int, slow: Bool) -> Int {
  let assert Ok(event) = body.next(body, 5000)
  case event {
    body.End(_) -> total
    body.Chunk(bytes) -> {
      case slow {
        True -> pause(1)
        False -> Nil
      }
      drain(body, total + bit_array.byte_size(bytes), slow)
    }
  }
}

fn large_stream(slow: Bool) {
  let bytes = 33_554_432
  let c = settings(False)
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        limits: config.Limits(
          ..c.limits,
          chunk_bytes: 524_288,
          queue_bytes: 1_048_576,
        ),
      ),
    )
  let sample = sampler()
  let started = now()
  let assert Ok(actual) =
    http_gun.with_response(client, req(large(bytes), False, "/"), fn(reply) {
      drain(reply.body, 0, slow)
    })
  let assert True = actual == bytes
  emit(
    case slow {
      True -> "large-slow-reader"
      False -> "large-stream"
    },
    1,
    now() - started,
    [],
    1,
    measured(sample),
    actual,
  )
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn mixed() {
  let port = h2()
  let assert Ok(client) = http_gun.start(settings(True))
  let sample = sampler()
  let started = now()
  let assert Ok(slow) = http_gun.open(client, req(port, True, "/slow"))
  let assert Ok(replies) =
    http_gun.batch(client, list.repeat(req(port, True, "/fast"), 1000), 64)
  let assert True = list.all(replies, result.is_ok)
  let assert Ok(_) = body.next(slow.body, 1000)
  let assert Ok(Nil) = body.close(slow.body)
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 1 = stats.connections
  emit(
    "h2-slow-stream-plus-batch",
    1000,
    now() - started,
    [],
    stats.connections,
    measured(sample),
    3000,
  )
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

pub fn main() {
  list.each([1, 10, 100, 1000], fn(count) {
    concurrent(False, count)
    concurrent(True, count)
  })
  large_stream(False)
  large_stream(True)
  mixed()
}
