//// Decides which hosts, ports and network addresses a client may reach.
////
//// A `Policy` admits public addresses by default. The three setups that tests
//// and local services need are each one line:
////
//// ```gleam
//// // Public addresses and loopback.
//// config.default() |> config.allow_loopback
//// // Loopback only.
//// config.default() |> config.with_destination(destination.loopback_only())
//// // Loopback, pinned to one local server.
//// config.default()
//// |> config.with_destination(
////   destination.loopback_only() |> destination.only_hosts(["127.0.0.1:8080"]),
//// )
//// ```
////
//// `allow_private` admits private networks. Reserved addresses, including
//// cloud metadata addresses, are always refused. Every address that a host
//// name resolves to is checked before a connection opens, and the connection
//// uses that checked address.
////
//// `http_gun.with_destination` narrows the policy for one client view: a
//// request must satisfy both the client's policy and every policy its view
//// adds, so a view can never widen what the client admits. `check` applies a
//// policy to a host and port without resolving names, for an application
//// that validates URLs itself.

import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string

/// An IP address. `parse_address` reads one from text.
pub type Address {
  Ipv4(Int, Int, Int, Int)
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

/// The class of an address, as `classify` reports it.
pub type Class {
  Public
  Loopback
  Private
  Reserved
}

/// Why a policy refused a destination.
pub type Rejection {
  /// The host, or its port, is not in the `only_hosts` list.
  HostNotAllowed
  /// The host is, or resolved to, an address whose class the policy refuses.
  AddressRefused(Class)
}

/// Which destinations a client admits. Build one with `default` or
/// `loopback_only` and the functions below.
pub opaque type Policy {
  Policy(
    allow_public: Bool,
    allow_loopback: Bool,
    allow_private: Bool,
    allowed: Option(List(String)),
  )
}

/// Public addresses only.
pub fn default() -> Policy {
  Policy(
    allow_public: True,
    allow_loopback: False,
    allow_private: False,
    allowed: None,
  )
}

/// Loopback addresses only (127.0.0.0/8 and ::1): public, private and
/// reserved addresses are refused.
pub fn loopback_only() -> Policy {
  Policy(
    allow_public: False,
    allow_loopback: True,
    allow_private: False,
    allowed: None,
  )
}

/// Also admit loopback addresses.
pub fn allow_loopback(policy: Policy) -> Policy {
  Policy(..policy, allow_loopback: True)
}

/// Also admit private network addresses: 10.0.0.0/8, 172.16.0.0/12,
/// 192.168.0.0/16, 100.64.0.0/10 and fc00::/7.
pub fn allow_private(policy: Policy) -> Policy {
  Policy(..policy, allow_private: True)
}

/// Admit only these hosts, compared without case. An entry is `"host"`, which
/// admits every port, or `"host:port"`, which admits one port; write an IPv6
/// address with a port as `"[::1]:8080"`. Address classes still apply, so
/// `loopback_only() |> only_hosts(["127.0.0.1:8080"])` admits exactly one
/// local server. Calling it again replaces the list.
pub fn only_hosts(policy: Policy, hosts: List(String)) -> Policy {
  Policy(..policy, allowed: Some(list.map(hosts, string.lowercase)))
}

/// Return the first malformed `only_hosts` entry: empty, containing
/// whitespace, `/`, `?`, `#` or `@`, or with a port outside 1..65535. A
/// malformed entry never matches a request; `config.validate` and
/// `http_gun.start` report it.
pub fn validate(policy: Policy) -> Result(Policy, String) {
  case policy.allowed {
    None -> Ok(policy)
    Some(hosts) ->
      case list.find(hosts, fn(entry) { result.is_error(parse_entry(entry)) }) {
        Ok(bad) -> Error(bad)
        Error(Nil) -> Ok(policy)
      }
  }
}

/// Check a host and port against the policy without resolving names. A host
/// that is an IP literal (with or without brackets) is also classified;
/// a host name passes when the host list admits it, and its resolved
/// addresses are checked again when a client connects.
pub fn check(
  policy: Policy,
  host: String,
  port: Int,
) -> Result(Nil, Rejection) {
  let host = string.lowercase(unbracket(host))
  use Nil <- result.try(check_host(policy, host, port))
  case parse_address(host) {
    Ok(address) -> check_address(policy, address)
    Error(Nil) -> Ok(Nil)
  }
}

/// Check one resolved address against the policy's address classes.
pub fn check_address(
  policy: Policy,
  address: Address,
) -> Result(Nil, Rejection) {
  let class = classify(address)
  let permitted = case class {
    Public -> policy.allow_public
    Loopback -> policy.allow_loopback
    Private -> policy.allow_private
    Reserved -> False
  }
  case permitted {
    True -> Ok(Nil)
    False -> Error(AddressRefused(class))
  }
}

fn check_host(
  policy: Policy,
  host: String,
  port: Int,
) -> Result(Nil, Rejection) {
  case policy.allowed {
    None -> Ok(Nil)
    Some(entries) ->
      case
        list.any(entries, fn(entry) {
          case parse_entry(entry) {
            Ok(#(name, None)) -> name == host
            Ok(#(name, Some(allowed))) -> name == host && allowed == port
            Error(Nil) -> False
          }
        })
      {
        True -> Ok(Nil)
        False -> Error(HostNotAllowed)
      }
  }
}

// "host", "host:port", "[v6]" or "[v6]:port". A bare IPv6 literal has
// several colons and no port.
fn parse_entry(entry: String) -> Result(#(String, Option(Int)), Nil) {
  use Nil <- result.try(
    case
      entry != ""
      && !list.any(
        [" ", "\t", "\r", "\n", "\u{0}", "/", "?", "#", "@"],
        string.contains(entry, _),
      )
    {
      True -> Ok(Nil)
      False -> Error(Nil)
    },
  )
  case string.starts_with(entry, "[") {
    True ->
      case string.split_once(string.drop_start(entry, 1), "]") {
        Ok(#(host, "")) if host != "" -> Ok(#(host, None))
        Ok(#(host, ":" <> port)) if host != "" ->
          result.map(parse_port(port), fn(port) { #(host, Some(port)) })
        _ -> Error(Nil)
      }
    False ->
      case string.split(entry, ":") {
        [host] -> Ok(#(host, None))
        [host, port] if host != "" ->
          result.map(parse_port(port), fn(port) { #(host, Some(port)) })
        _ ->
          case parse_address(entry) {
            Ok(Ipv6(..)) -> Ok(#(entry, None))
            _ -> Error(Nil)
          }
      }
  }
}

fn parse_port(text: String) -> Result(Int, Nil) {
  case int.parse(text) {
    Ok(port) if port >= 1 && port <= 65_535 -> Ok(port)
    _ -> Error(Nil)
  }
}

fn unbracket(host: String) -> String {
  case string.starts_with(host, "[") && string.ends_with(host, "]") {
    True -> host |> string.drop_start(1) |> string.drop_end(1)
    False -> host
  }
}

/// Parse an IPv4 or IPv6 literal, as `"127.0.0.1"` or `"::1"`.
pub fn parse_address(text: String) -> Result(Address, Nil) {
  parse_strict(text)
}

@external(erlang, "http_gun_ffi", "parse_address")
fn parse_strict(text: String) -> Result(Address, Nil)

/// Classify an address. Invalid components fail closed as `Reserved`.
/// IPv4-mapped and well-known NAT64 IPv6 addresses inherit the embedded IPv4
/// classification.
pub fn classify(address: Address) -> Class {
  let #(parts, maximum) = case address {
    Ipv4(a, b, c, d) -> #([a, b, c, d], 255)
    Ipv6(a, b, c, d, e, f, g, h) -> #([a, b, c, d, e, f, g, h], 65_535)
  }
  case list.all(parts, fn(part) { part >= 0 && part <= maximum }) {
    False -> Reserved
    True -> classify_valid(address)
  }
}

fn classify_valid(address: Address) -> Class {
  case address {
    Ipv4(100, 100, 100, 200) -> Reserved
    Ipv4(127, _, _, _) -> Loopback
    Ipv4(10, _, _, _) | Ipv4(192, 168, _, _) -> Private
    Ipv4(172, b, _, _) if b >= 16 && b <= 31 -> Private
    Ipv4(100, b, _, _) if b >= 64 && b <= 127 -> Private
    Ipv4(0, _, _, _) | Ipv4(169, 254, _, _) -> Reserved
    Ipv4(a, _, _, _) if a >= 224 -> Reserved
    Ipv4(192, 0, 0, _)
    | Ipv4(192, 0, 2, _)
    | Ipv4(192, 88, 99, _)
    | Ipv4(198, 51, 100, _)
    | Ipv4(203, 0, 113, _) -> Reserved
    Ipv4(198, b, _, _) if b == 18 || b == 19 -> Reserved
    Ipv4(..) -> Public
    Ipv6(0, 0, 0, 0, 0, 0, 0, 1) -> Loopback
    Ipv6(0, 0, 0, 0, 0, 0xFFFF, g, h) | Ipv6(0x64, 0xFF9B, 0, 0, 0, 0, g, h) ->
      classify_valid(Ipv4(g / 256, g % 256, h / 256, h % 256))
    Ipv6(0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254) -> Reserved
    Ipv6(a, _, _, _, _, _, _, _) if a >= 0xFC00 && a <= 0xFDFF -> Private
    Ipv6(0x2001, 0xDB8, _, _, _, _, _, _)
    | Ipv6(0x2001, 0, _, _, _, _, _, _)
    | Ipv6(0x2001, 2, 0, _, _, _, _, _)
    | Ipv6(0x2002, _, _, _, _, _, _, _) -> Reserved
    Ipv6(0x2001, b, _, _, _, _, _, _) if b >= 0x10 && b <= 0x2F -> Reserved
    Ipv6(0x3FFF, b, _, _, _, _, _, _) if b < 0x1000 -> Reserved
    // Only global unicast is public; unspecified, link-local, multicast,
    // discard-only 100::/64 and other special space fail closed here.
    Ipv6(a, _, _, _, _, _, _, _) if a >= 0x2000 && a <= 0x3FFF -> Public
    Ipv6(..) -> Reserved
  }
}
