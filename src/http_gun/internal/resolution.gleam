import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import http_gun/destination
import http_gun/error
import http_gun/internal/bridge
import http_gun/internal/preparation

pub type Resolved {
  Resolved(address: destination.Address, server_name: Option(String))
}

// Resolution policy stays here; preparation owns only bounded worker lifetime.
pub fn start(
  owner: process.Pid,
  policy: destination.Policy,
  host: String,
  until: Int,
  reply: fn(process.Pid, Result(Resolved, error.Reason)) -> Nil,
) -> process.Pid {
  preparation.start(
    owner,
    until,
    error.ResolutionFailed,
    fn() { resolve(policy, host, until) },
    reply,
  )
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
        Some(resolver) -> resolver(host, preparation.remaining(until))
        None -> lookup(host, until)
      }
      #(answer, Some(host))
    }
  }
  use Nil <- result.try(case preparation.remaining(until) {
    0 -> Error(error.DeadlineExceeded)
    _ -> Ok(Nil)
  })
  use addresses <- result.try(
    result.map_error(answer, fn(_) { error.ResolutionFailed }),
  )
  case addresses, preparation.remaining(until) {
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
  use v4 <- result.try(bridge.lookup(
    host,
    bridge.Inet,
    preparation.remaining(until),
  ))
  use v6 <- result.try(bridge.lookup(
    host,
    bridge.Inet6,
    preparation.remaining(until),
  ))
  Ok(list.append(v4, v6))
}
