import gleam/erlang/process
import http_gun/error
import http_gun/internal/bridge

type Event(value) {
  Answer(Result(value, error.Reason))
  Stopped
}

// A finite connection-preparation job, owned by its pool and request budget.
// Used for DNS and supported Gun readiness inspection. Neither job runs on the
// pool actor. The linked worker cannot outlive this guardian.
pub fn start(
  owner: process.Pid,
  until: Int,
  failed: error.Reason,
  work: fn() -> Result(value, error.Reason),
  reply: fn(process.Pid, Result(value, error.Reason)) -> Nil,
) -> process.Pid {
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let monitor = process.monitor(owner)
    let answers = process.new_subject()
    let worker = process.spawn(fn() { process.send(answers, Answer(work())) })
    let received =
      process.new_selector()
      |> process.select(answers)
      |> process.select_specific_monitor(monitor, fn(_) { Stopped })
      |> process.select_trapped_exits(fn(_) { Answer(Error(failed)) })
      |> process.selector_receive(within: remaining(until))
    process.kill(worker)
    process.demonitor_process(monitor)
    case received {
      Ok(Stopped) -> Nil
      Ok(Answer(value)) -> reply(process.self(), value)
      Error(_) -> reply(process.self(), Error(error.DeadlineExceeded))
    }
  })
}

pub fn remaining(until: Int) -> Int {
  let value = until - bridge.now()
  case value > 0 {
    True -> value
    False -> 0
  }
}
