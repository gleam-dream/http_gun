//// The validated client settings record behind `config.Config`. Only
//// `http_gun/config` builds it; the pool, body owners and recorder read it.

import gleam/option.{type Option}
import http_gun/destination
import http_gun/redaction
import sinal/forwarder

// Constructor names match the atoms http_gun_ffi:open/9 expects.
pub type Protocol {
  Http1
  PreferHttp2
  RequireHttp2
}

pub type Trust {
  SystemTrust
  CustomCa(String)
  Anchors(List(BitArray))
}

pub type Negotiated {
  H1
  H2
  Offline
}

/// A duration in milliseconds, or no bound.
pub type Bound {
  Within(Int)
  Unbounded
}

/// Where a client's lifecycle events go.
pub type Observations {
  /// `sinal.emit`, which follows the application's routes. The default.
  Emit
  /// One forwarder, bypassing the application's routes.
  Forward(forwarder.Forwarder)
  /// Nowhere.
  Silent
}

pub type Resolver =
  fn(String, Int) -> Result(List(destination.Address), Nil)

pub type Limits {
  Limits(
    connections: Int,
    per_origin: Int,
    streams_per_connection: Int,
    open_bodies: Int,
    queued_requests: Int,
    request_body_bytes: Int,
    header_bytes: Int,
    header_count: Int,
    buffered_bytes: Int,
    response_body_bytes: Int,
    batch_bytes: Int,
  )
}

pub type Settings {
  Settings(
    protocol: Protocol,
    trust: Trust,
    connect_timeout: Int,
    pool_timeout: Int,
    request_timeout: Bound,
    idle_timeout: Bound,
    connection_idle_timeout: Int,
    shutdown_timeout: Int,
    limits: Limits,
    observations: Observations,
    label: Option(String),
    destination: destination.Policy,
    resolver: Option(Resolver),
    redaction: redaction.Redaction,
  )
}

/// The absolute monotonic instant a bound ends, from `now`.
pub fn until(bound: Bound, now: Int) -> Option(Int) {
  case bound {
    Within(ms) -> option.Some(now + ms)
    Unbounded -> option.None
  }
}
