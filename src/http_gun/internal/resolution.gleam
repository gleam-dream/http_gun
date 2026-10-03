import gleam/erlang/process
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/time/duration
import http_gun/destination
import http_gun/error
import http_gun/internal/bridge
import http_gun/internal/preparation
import http_gun/internal/settings

pub type Resolved {
  Resolved(
    address: destination.Address,
    server_name: Option(String),
    /// The complete checked answer. A request reusing the connection must
    /// admit every one of these addresses.
    addresses: List(destination.Address),
  )
}

// Resolution policy stays here; preparation owns only bounded worker lifetime.
pub fn start(
  owner: process.Pid,
  policies: List(destination.Policy),
  resolver: Option(settings.Resolver),
  host: String,
  port: Int,
  tls: Bool,
  until: Int,
  reply: fn(process.Pid, Result(Resolved, error.Reason)) -> Nil,
) -> process.Pid {
  preparation.start(
    owner,
    until,
    error.ResolutionFailed,
    fn() { resolve(policies, resolver, host, port, tls, until) },
    reply,
  )
}

/// Every policy must admit the host, port and each address, and, without
/// TLS, admit plaintext to each address.
pub fn admit(
  policies: List(destination.Policy),
  host: String,
  port: Int,
  tls: Bool,
  addresses: List(destination.Address),
) -> Result(Nil, error.Reason) {
  list.try_each(policies, fn(policy) {
    use Nil <- result.try(destination.check(policy, host, port))
    use Nil <- result.try(
      list.try_each(addresses, destination.check_address(policy, _)),
    )
    case tls {
      True -> Ok(Nil)
      False -> list.try_each(addresses, destination.check_plaintext(policy, _))
    }
  })
  |> result.map_error(error.DestinationRejected)
}

fn resolve(
  policies: List(destination.Policy),
  resolver: Option(settings.Resolver),
  host: String,
  port: Int,
  tls: Bool,
  until: Int,
) -> Result(Resolved, error.Reason) {
  use Nil <- result.try(admit(policies, host, port, tls, []))
  let #(answer, name) = case destination.parse_address(host) {
    Ok(address) -> #(Ok([address]), None)
    Error(_) -> {
      let answer = case resolver {
        Some(resolver) ->
          resolver(host, duration.milliseconds(preparation.remaining(until)))
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
    [first, ..], _ -> {
      use Nil <- result.try(admit(policies, host, port, tls, addresses))
      Ok(Resolved(first, name, addresses))
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
