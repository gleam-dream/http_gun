//// Independent nghttpd interoperability and practical local measurements.

import gleam/bit_array
import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result
import http_gun
import http_gun/body
import http_gun/config
import simplifile

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

@external(erlang, "http_gun_measure_ffi", "sampler")
fn sampler() -> process.Pid

@external(erlang, "http_gun_measure_ffi", "finish")
fn measured(pid: process.Pid) -> #(Int, Int, Int, Int, Int)

@external(erlang, "http_gun_measure_ffi", "pause")
fn pause(ms: Int) -> Nil

fn read_int(path: String) -> Int {
  let assert Ok(text) = simplifile.read(path)
  let assert Ok(value) = int.parse(text)
  value
}

fn req(port: Int, path: String) -> request.Request(BitArray) {
  request.new()
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_path(path)
  |> request.set_body(<<>>)
}

fn payload() -> BitArray {
  int.range(0, 256, <<>>, fn(acc, byte) { <<acc:bits, byte>> })
}

fn check(reply: http_gun.Buffered) -> Nil {
  let assert config.H2 = reply.protocol
  let assert True = reply.response.body == payload()
  let assert [#("x-final", "yes")] = reply.trailers
  Nil
}

fn percentile(times: List(Int), percentage: Int) -> Int {
  times
  |> list.drop(int.max(0, list.length(times) * percentage / 100 - 1))
  |> list.first
  |> result.unwrap(0)
}

fn report(
  label: String,
  count: Int,
  started: Int,
  times: List(Int),
  sample: process.Pid,
  bytes: Int,
) -> Nil {
  let elapsed = now() - started
  let stats = measured(sample)
  let sorted = list.sort(times, int.compare)
  io.println(
    json.object([
      #("scenario", json.string(label)),
      #(
        "latency_kind",
        json.string(case label {
          "nghttpd-slow-stream-plus-batch" -> "local_cancel_to_empty_snapshot"
          _ -> "request_when_sampled"
        }),
      ),
      #("requests", json.int(count)),
      #("elapsed_us", json.int(elapsed)),
      #("p50_us", case times {
        [] -> json.null()
        _ -> json.int(percentile(sorted, 50))
      }),
      #("p95_us", case times {
        [] -> json.null()
        _ -> json.int(percentile(sorted, 95))
      }),
      #("p99_us", case times {
        [] -> json.null()
        _ -> json.int(percentile(sorted, 99))
      }),
      #("connections", json.int(1)),
      #("peak_vm_bytes", json.int(stats.0)),
      #("peak_total_mailbox", json.int(stats.1)),
      #("peak_one_mailbox", json.int(stats.2)),
      #("peak_processes", json.int(stats.3)),
      #("peak_ports", json.int(stats.4)),
      #("bytes", json.int(bytes)),
    ])
    |> json.to_string,
  )
}

fn gather(
  done: process.Subject(Int),
  count: Int,
  times: List(Int),
) -> List(Int) {
  case count {
    0 -> times
    _ -> {
      let assert Ok(time) = process.receive(done, 60_000)
      gather(done, count - 1, [time, ..times])
    }
  }
}

fn concurrent(
  client: http_gun.Client,
  req: request.Request(BitArray),
  count: Int,
) -> Nil {
  let sample = sampler()
  let started = now()
  let done = process.new_subject()
  list.each(list.repeat(Nil, count), fn(_) {
    // Timestamp before spawning so queued caller scheduling remains visible.
    let arrival = now()
    let _ =
      process.spawn(fn() {
        let assert Ok(reply) = http_gun.send(client, req)
        check(reply)
        process.send(done, now() - arrival)
      })
    Nil
  })
  let times = gather(done, count, [])
  report("nghttpd-concurrent", count, started, times, sample, count * 256)
}

fn drain(stream: body.Body, bytes: Int) -> Int {
  let assert Ok(part) = body.next(stream, 5000)
  case part {
    body.Chunk(chunk) -> drain(stream, bytes + bit_array.byte_size(chunk))
    body.End(trailers) -> {
      let assert [#("x-final", "yes")] = trailers
      bytes
    }
  }
}

fn mixed(client: http_gun.Client, port: Int) -> Nil {
  let sample = sampler()
  let start = now()
  let assert Ok(slow) = http_gun.open(client, req(port, "/large"))
  let assert config.H2 = body.protocol(slow.body)
  let assert Ok(body.Chunk(_)) = body.next(slow.body, 1000)
  // No further demand on the large stream while 1000 siblings finish.
  let assert Ok(replies) =
    http_gun.batch(client, list.repeat(req(port, "/bytes"), 1000), 32)
  list.each(replies, fn(reply) {
    let assert Ok(reply) = reply
    check(reply)
  })
  let cancel = now()
  let assert Ok(Nil) = body.close(slow.body)
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 1 = stats.connections
  let assert 0 = stats.bodies
  report(
    "nghttpd-slow-stream-plus-batch",
    1000,
    start,
    [now() - cancel],
    sample,
    256_000,
  )
  // A second cancellation while a sibling is itself still being streamed.
  let assert Ok(cancelled) = http_gun.open(client, req(port, "/large"))
  let assert Ok(sibling) = http_gun.open(client, req(port, "/large"))
  let assert Ok(Nil) = body.close(cancelled.body)
  let sample = sampler()
  let start = now()
  let bytes = drain(sibling.body, 0)
  let assert 33_554_432 = bytes
  let assert Ok(Nil) = body.close(sibling.body)
  report("nghttpd-large-surviving-sibling", 1, start, [], sample, bytes)
}

fn steady(
  client: http_gun.Client,
  request: request.Request(BitArray),
  until: Int,
  completed: Int,
) -> Int {
  case now() >= until {
    True -> completed
    False -> {
      let assert Ok(replies) =
        http_gun.batch(client, list.repeat(request, 100), 8)
      list.each(replies, fn(reply) {
        let assert Ok(reply) = reply
        check(reply)
      })
      // A controlled offered load, with bounded batches and time for quiescence.
      pause(10)
      steady(client, request, until, completed + 100)
    }
  }
}

pub fn main() -> Nil {
  let port = read_int("build/evidence/nghttpd/port")
  let duration = read_int("build/evidence/nghttpd/duration")
  let defaults = config.default()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..defaults,
        protocol: config.RequireHttp2,
        trust: config.CustomCa("test/fixtures/ca.crt"),
        deadline_ms: 60_000,
        limits: config.Limits(
          ..defaults.limits,
          connections: 1,
          per_origin: 1,
          waiting: 1024,
        ),
      ),
    )
  let sample = sampler()
  let start = now()
  let assert Ok(cold) = http_gun.send(client, req(port, "/bytes"))
  check(cold)
  report("nghttpd-cold", 1, start, [now() - start], sample, 256)
  let upload =
    req(port, "/bytes")
    |> request.set_method(http.Put)
    |> request.set_body(payload())
  let assert Ok(uploaded) = http_gun.send(client, upload)
  check(uploaded)
  let assert Ok(missing) = http_gun.send(client, req(port, "/missing"))
  let assert 404 = missing.response.status
  let assert Ok(head) =
    http_gun.send(client, req(port, "/bytes") |> request.set_method(http.Head))
  let assert <<>> = head.response.body
  list.each([1, 10, 100, 1000], fn(count) {
    concurrent(client, req(port, "/bytes"), count)
  })
  mixed(client, port)
  case duration > 0 {
    False -> Nil
    True -> {
      let sample = sampler()
      let start = now()
      let count =
        steady(client, req(port, "/bytes"), start + duration * 1_000_000, 0)
      report("nghttpd-steady", count, start, [], sample, count * 256)
    }
  }
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 1 = stats.connections
  let assert 0 = stats.bodies
  let assert 0 = stats.waiting
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}
