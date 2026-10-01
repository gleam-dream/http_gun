import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun/destination
import http_gun/error
import http_gun/internal/bridge

pub type Resolved {
  Resolved(address: destination.Address, server_name: Option(String))
}

type Event {
  Answer(Result(Resolved, error.Reason))
  Stopped
}

// One bounded job per connection reservation. The guardian can stop a blocked
// native lookup or injected resolver when its pool dies. Its linked worker has
// no pool state/request body, and never sends to the HTTP caller.
pub fn start(
  owner: process.Pid,
  policy: destination.Policy,
  host: String,
  until: Int,
  reply: fn(process.Pid, Result(Resolved, error.Reason)) -> Nil,
) -> process.Pid {
  process.spawn_unlinked(fn() {
    process.trap_exits(True)
    let monitor = process.monitor(owner)
    let answers = process.new_subject()
    let worker =
      process.spawn(fn() {
        process.send(answers, Answer(resolve(policy, host, until)))
      })
    let received =
      process.new_selector()
      |> process.select(answers)
      |> process.select_specific_monitor(monitor, fn(_) { Stopped })
      |> process.select_trapped_exits(fn(_) {
        Answer(Error(error.ResolutionFailed))
      })
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

fn remaining(until: Int) -> Int {
  let value = until - bridge.now()
  case value > 0 {
    True -> value
    False -> 0
  }
}

fn resolve(
  policy: destination.Policy,
  host: String,
  until: Int,
) -> Result(Resolved, error.Reason) {
  use Nil <- result.try(case destination.permits_host(policy, host) {
    True -> Ok(Nil)
    False -> Error(error.DestinationRejected)
  })
  let #(answer, name) = case bridge.parse_address(host) {
    Ok(address) -> #(Ok([address]), None)
    Error(_) -> {
      let answer = case policy.resolver {
        Some(resolver) -> resolver(host, remaining(until))
        None -> lookup(host, until)
      }
      #(answer, Some(host))
    }
  }
  use Nil <- result.try(case remaining(until) {
    0 -> Error(error.DeadlineExceeded)
    _ -> Ok(Nil)
  })
  use addresses <- result.try(
    result.map_error(answer, fn(_) { error.ResolutionFailed }),
  )
  case addresses, remaining(until) {
    _, 0 -> Error(error.DeadlineExceeded)
    [], _ -> Error(error.ResolutionFailed)
    [first, ..], _ ->
      case list.all(addresses, destination.permits(policy, _)) {
        True -> Ok(Resolved(first, name))
        False -> Error(error.DestinationRejected)
      }
  }
}

fn lookup(host: String, until: Int) -> Result(List(destination.Address), Nil) {
  use v4 <- result.try(bridge.lookup(host, bridge.Inet, remaining(until)))
  use v6 <- result.try(bridge.lookup(host, bridge.Inet6, remaining(until)))
  Ok(list.append(v4, v6))
}
