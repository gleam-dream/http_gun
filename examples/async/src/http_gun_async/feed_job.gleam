//// Application recipe using public APIs. This module is not an HTTP Gun API.
//// One opening/reading worker and one monitor-only guardian per admitted job.
//// The application must bound concurrent jobs and the work performed by its sink.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/otp/actor
import gleam/otp/static_supervisor
import gleam/result
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error

pub type Decision {
  Continue
  Stop
}

pub type Completion {
  Eof(bytes: Int, trailers: List(#(String, String)))
  Early(bytes: Int)
}

pub type Problem {
  Http(error.Failure)
  SinkFailed
  WorkerStopped
  WaitExpired
  WrongCaller
  ShutdownTimeout
}

pub opaque type Job {
  Job(
    worker: process.Pid,
    token: cancellation.Token,
    owner: process.Pid,
    done: process.Subject(Result(Completion, Problem)),
  )
}

/// Start the application's one shared client under a supervisor. The client
/// registers under `name`; `http_gun.named(name)` is a handle that keeps
/// working across restarts, so jobs never need a fresh capability.
pub fn supervise(
  settings: config.Config,
  name: process.Name(http_gun.Message),
) -> actor.StartResult(static_supervisor.Supervisor) {
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(http_gun.supervised(settings, name))
  |> static_supervisor.start
}

/// The sink runs synchronously in the worker. Only after it returns Continue is
/// another read requested. No chunks are forwarded into a consumer mailbox.
pub fn start(
  client: http_gun.Client,
  req: request.Request(BitArray),
  budget: deadline.Deadline,
  sink: fn(BitArray) -> Result(Decision, Nil),
) -> Result(Job, Problem) {
  let owner = process.self()
  let ready = process.new_subject()
  let done = process.new_subject()
  let worker =
    process.spawn_unlinked(fn() {
      let worker = process.self()
      let _ = process.spawn_unlinked(fn() { guard(owner, worker) })
      // The token scope is the worker's: returning, raising or dying cancels
      // the request. The token reaches the caller before opening begins, so a
      // cancel works even while the server withholds the response head.
      let outcome = {
        use token <- cancellation.with_token
        process.send(ready, token)
        let client =
          client
          |> http_gun.with_deadline(budget)
          |> http_gun.with_cancellation(token)
        use response <- http_gun.with_response(client, req, Http)
        read(response.body, sink, 0)
      }
      process.send(done, outcome)
    })
  let monitor = process.monitor(worker)
  let outcome =
    process.new_selector()
    |> process.select_map(ready, Ok)
    |> process.select_specific_monitor(monitor, fn(_) { Error(WorkerStopped) })
    |> process.selector_receive(1000)
    |> result.unwrap(Error(WaitExpired))
  process.demonitor_process(monitor)
  case outcome {
    Ok(token) -> Ok(Job(worker, token, owner, done))
    Error(problem) -> {
      process.kill(worker)
      Error(problem)
    }
  }
}

fn guard(owner: process.Pid, worker: process.Pid) -> Nil {
  let owner_monitor = process.monitor(owner)
  let worker_monitor = process.monitor(worker)
  let owner_lost =
    process.new_selector()
    |> process.select_specific_monitor(owner_monitor, fn(_) { True })
    |> process.select_specific_monitor(worker_monitor, fn(_) { False })
    |> process.selector_receive_forever
  case owner_lost {
    True -> process.kill(worker)
    False -> Nil
  }
  process.demonitor_process(owner_monitor)
  process.demonitor_process(worker_monitor)
}

fn read(
  source: body.Body,
  sink: fn(BitArray) -> Result(Decision, Nil),
  bytes: Int,
) -> Result(Completion, Problem) {
  // `next` waits for bytes; the deadline, the idle timeout and the token
  // bound the wait, so the recipe needs no local read loop.
  case body.next(source) {
    Ok(body.End(trailers)) -> Ok(Eof(bytes, trailers))
    Ok(body.Chunk(chunk)) -> {
      let bytes = bytes + bit_array.byte_size(chunk)
      use decision <- result.try(
        sink(chunk) |> result.map_error(fn(_) { SinkFailed }),
      )
      case decision {
        Stop -> Ok(Early(bytes))
        Continue -> read(source, sink, bytes)
      }
    }
    Error(failure) -> Error(Http(failure))
  }
}

/// Only the creating application process awaits the one completion value.
/// WaitExpired does not cancel the job. A copied Job does not transfer lifetime.
pub fn await(job: Job, wait_ms: Int) -> Result(Completion, Problem) {
  case process.self() == job.owner {
    False -> Error(WrongCaller)
    True -> {
      let monitor = process.monitor(job.worker)
      let outcome =
        process.new_selector()
        |> process.select_map(job.done, fn(result) { result })
        |> process.select_specific_monitor(monitor, fn(_) {
          Error(WorkerStopped)
        })
        |> process.selector_receive(wait_ms)
        |> result.unwrap(Error(WaitExpired))
      process.demonitor_process(monitor)
      outcome
    }
  }
}

/// Idempotent cancellation; HTTP cleanup proceeds asynchronously.
pub fn cancel(job: Job) -> Nil {
  cancellation.cancel(job.token)
}

/// Bound the application's shutdown wait even if a sink is stuck. At the bound,
/// kill only our worker; opener death releases HTTP resources asynchronously.
/// This waits for worker death, not a remote acknowledgement or a pool barrier.
pub fn shutdown(job: Job, grace_ms: Int) -> Result(Nil, Problem) {
  let monitor = process.monitor(job.worker)
  let canceller =
    process.spawn_unlinked(fn() { cancellation.cancel(job.token) })
  let selector =
    process.new_selector()
    |> process.select_specific_monitor(monitor, fn(_) { Nil })
  let outcome = case process.selector_receive(selector, grace_ms) {
    Ok(Nil) -> Ok(Nil)
    Error(Nil) -> {
      process.kill(job.worker)
      process.selector_receive(selector, 1000)
      |> result.map_error(fn(_) { ShutdownTimeout })
    }
  }
  process.kill(canceller)
  process.demonitor_process(monitor)
  outcome
}
