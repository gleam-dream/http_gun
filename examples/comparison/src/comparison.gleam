import comparison_adapter as adapter
import gleam/erlang/process
import gleam/int
import gleam/io
import gleam/json
import gleam/list
import gleam/result

@external(erlang, "comparison_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "http_gun_measure_ffi", "now")
fn now() -> Int

@external(erlang, "http_gun_measure_ffi", "sampler")
fn sampler() -> process.Pid

@external(erlang, "http_gun_measure_ffi", "finish")
fn finish(pid: process.Pid) -> #(Int, Int, Int, Int, Int)

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

@external(erlang, "http_gun_measure_ffi", "large")
fn large(bytes: Int) -> Int

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

@external(erlang, "comparison_ffi", "mixed")
fn mixed_server() -> Int

fn percentile(xs: List(Int), n: Int) -> Int {
  list.drop(xs, int.max(0, list.length(xs) * n / 100 - 1))
  |> list.first
  |> result.unwrap(0)
}

fn gather(
  done: process.Subject(#(Int, Result(String, String))),
  n: Int,
  acc: List(#(Int, Result(String, String))),
) -> List(#(Int, Result(String, String))) {
  case n {
    0 -> acc
    _ -> {
      let assert Ok(r) = process.receive(done, 65_000)
      gather(done, n - 1, [r, ..acc])
    }
  }
}

fn concurrent(
  client: adapter.Client,
  port: Int,
  count: Int,
) -> List(#(Int, Result(String, String))) {
  let done = process.new_subject()
  list.each(list.repeat(Nil, count), fn(_) {
    let _ = process.spawn(fn() { one(client, port, done) })
    Nil
  })
  gather(done, count, [])
}

fn one(
  client: adapter.Client,
  port: Int,
  done: process.Subject(#(Int, Result(String, String))),
) -> Nil {
  let started = now()
  let response =
    adapter.send(client, port, False)
    |> result.try(fn(r) {
      case r.bytes == <<"abc":utf8>> && r.status == 200 {
        True ->
          list.key_find(r.headers, "x-connection")
          |> result.map_error(fn(_) { "missing socket identity" })
        False -> Error("unexpected response")
      }
    })
  process.send(done, #(now() - started, response))
}

fn worker(
  client: adapter.Client,
  port: Int,
  count: Int,
  done: process.Subject(#(Int, Result(String, String))),
) -> Nil {
  case count {
    0 -> Nil
    _ -> {
      one(client, port, done)
      worker(client, port, count - 1, done)
    }
  }
}

fn bounded(
  client: adapter.Client,
  port: Int,
  count: Int,
) -> List(#(Int, Result(String, String))) {
  let done = process.new_subject()
  list.each([0, 1, 2, 3], fn(index) {
    let jobs =
      count
      / 4
      + case index < count % 4 {
        True -> 1
        False -> 0
      }
    let _ = process.spawn(fn() { worker(client, port, jobs, done) })
    Nil
  })
  gather(done, count, [])
}

fn run(
  client: adapter.Client,
  port: Int,
  scenario: String,
  count: Int,
) -> #(Int, List(#(Int, Result(String, String)))) {
  case scenario {
    "buffered" -> #(0, concurrent(client, port, count))
    "bounded" -> #(0, bounded(client, port, count))
    "mixed" -> {
      let ready = process.new_subject()
      let ended = process.new_subject()
      let _ =
        process.spawn(fn() {
          process.send(
            ended,
            adapter.stream(client, port, True, fn() { process.send(ready, Nil) }),
          )
        })
      let assert Ok(Nil) = process.receive(ready, 5000)
      let replies = concurrent(client, port, count)
      let assert Ok(Ok(bytes)) = process.receive(ended, 65_000)
      #(bytes, replies)
    }
    _ -> {
      let assert Ok(bytes) =
        adapter.stream(client, port, scenario == "slow", fn() { Nil })
      #(bytes, [])
    }
  }
}

pub fn main() {
  let assert [name, scenario, count, cap, trial] = arguments()
  let assert Ok(count) = int.parse(count)
  let assert Ok(cap) = int.parse(cap)
  let client = adapter.start(name, cap)
  // Warm this transport before sampling; each trial still has a fresh VM.
  let warm =
    serve(<<
      "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nabc":utf8,
    >>)
  let assert Ok(_) = adapter.send(client, warm, False)
  let port = case scenario {
    "buffered" | "bounded" -> {
      let p = server()
      let assert Ok(_) = adapter.send(client, p, False)
      p
    }
    "mixed" -> mixed_server()
    _ -> large(33_554_432)
  }
  let sample = sampler()
  let started = now()
  let #(bytes, replies) = run(client, port, scenario, count)
  let elapsed = now() - started
  let stats = finish(sample)
  let times = list.map(replies, fn(r) { r.0 }) |> list.sort(int.compare)
  let failures =
    list.filter_map(replies, fn(r) {
      case r.1 {
        Error(e) -> Ok(e)
        Ok(_) -> Error(Nil)
      }
    })
  let observed =
    list.filter_map(replies, fn(r) { r.1 }) |> list.unique |> list.length
  let sockets = case scenario {
    "large" | "slow" -> 1
    "mixed" -> observed + 1
    _ -> observed
  }
  io.println(
    json.object([
      #("client", json.string(name)),
      #("scenario", json.string(scenario)),
      #("requests", json.int(count)),
      #("connection_cap", json.int(cap)),
      #("trial", json.string(trial)),
      #("elapsed_us", json.int(elapsed)),
      #("p50_us", json.int(percentile(times, 50))),
      #("p95_us", json.int(percentile(times, 95))),
      #("p99_us", json.int(percentile(times, 99))),
      #("connections", json.int(sockets)),
      #("failures", json.int(list.length(failures))),
      #("failure_examples", json.array(list.take(failures, 3), json.string)),
      #(
        "bytes",
        json.int(bytes + { list.length(replies) - list.length(failures) } * 3),
      ),
      #("peak_vm_bytes", json.int(stats.0)),
      #("peak_total_mailbox", json.int(stats.1)),
      #("peak_one_mailbox", json.int(stats.2)),
      #("peak_processes", json.int(stats.3)),
      #("peak_ports", json.int(stats.4)),
    ])
    |> json.to_string,
  )
  adapter.stop(client)
}
