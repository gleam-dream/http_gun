/// Network destination policy. Reserved addresses are never permitted.
/// The optional allowlist restricts exact host names (case insensitive), not ports.
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Address {
  Ipv4(Int, Int, Int, Int)
  Ipv6(Int, Int, Int, Int, Int, Int, Int, Int)
}

pub type Class {
  Public
  Loopback
  Private
  Reserved
}

/// Called once per new hostname connection, in an isolated worker. The supplied
/// milliseconds are the remaining request budget. Return the complete A/AAAA
/// answer; every address is checked. Exceptions and empty answers fail closed.
pub type Resolver =
  fn(String, Int) -> Result(List(Address), Nil)

pub type Policy {
  Policy(
    allow_public: Bool,
    allow_loopback: Bool,
    allow_private: Bool,
    allowed_hosts: Option(List(String)),
    resolver: Option(Resolver),
  )
}

pub fn default() -> Policy {
  Policy(True, False, False, None, None)
}

@internal
pub fn valid(policy: Policy) -> Bool {
  case policy.allowed_hosts {
    None -> True
    Some(hosts) ->
      list.all(hosts, fn(host) {
        host != ""
        && !list.any(
          [" ", "\t", "\r", "\n", "\u{0}", "/", "?", "#", "@"],
          fn(c) { string.contains(host, c) },
        )
      })
  }
}

@internal
pub fn permits_host(policy: Policy, host: String) -> Bool {
  case policy.allowed_hosts {
    None -> True
    Some(hosts) ->
      list.any(hosts, fn(allowed) {
        string.lowercase(allowed) == string.lowercase(host)
      })
  }
}

@internal
pub fn permits(policy: Policy, address: Address) -> Bool {
  case classify(address) {
    Public -> policy.allow_public
    Loopback -> policy.allow_loopback
    Private -> policy.allow_private
    Reserved -> False
  }
}

/// Invalid integer components fail closed as Reserved. IPv4-mapped and the
/// well-known NAT64 prefix inherit the embedded IPv4 classification.
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
