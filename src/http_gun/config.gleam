/// Pure startup policy. All limits are checked before starting a client.
import gleam/bit_array
import gleam/list
import gleam/option.{type Option, None}
import gleam/result
import http_gun/destination
import sinal/forwarder

pub type Protocol {
  Http1
  PreferHttp2
  RequireHttp2
}

pub type Trust {
  SystemTrust
  CustomCa(path: String)
  /// DER-encoded CA certificates, replacing system trust without file IO.
  /// OTP validates certificate contents when opening a TLS connection.
  Anchors(certificates: List(BitArray))
}

pub type Limits {
  Limits(
    connections: Int,
    per_origin: Int,
    streams_per_connection: Int,
    active: Int,
    waiting: Int,
    request_bytes: Int,
    head_bytes: Int,
    header_count: Int,
    chunk_bytes: Int,
    queue_bytes: Int,
    collect_bytes: Int,
  )
}

pub type Config {
  Config(
    protocol: Protocol,
    trust: Trust,
    deadline_ms: Int,
    connect_ms: Int,
    limits: Limits,
    observations: Option(forwarder.Forwarder),
    destination: destination.Policy,
  )
}

/// Public destinations only, verified TLS, H1 and a finite 30-second budget.
/// Compose record updates before starting a client; no processes or IO are started.
pub fn default() -> Config {
  Config(
    Http1,
    SystemTrust,
    30_000,
    5000,
    Limits(
      16,
      4,
      100,
      128,
      128,
      1_048_576,
      16_384,
      100,
      65_536,
      131_072,
      8_388_608,
    ),
    None,
    destination.default(),
  )
}

/// Check supported policies and positive capacities without starting processes.
/// Returns the unchanged settings or a diagnostic for invalid configuration.
pub fn validate(config: Config) -> Result(Config, String) {
  use Nil <- result.try(case config.trust {
    Anchors(certificates) ->
      case
        certificates != []
        && list.all(certificates, fn(cert) {
          bit_array.bit_size(cert) > 0 && bit_array.bit_size(cert) % 8 == 0
        })
      {
        True -> Ok(Nil)
        False ->
          Error("trust anchors must contain nonempty whole-byte certificates")
      }
    SystemTrust | CustomCa(_) -> Ok(Nil)
  })
  use Nil <- result.try(case destination.valid(config.destination) {
    True -> Ok(Nil)
    False -> Error("destination allowlist entries must be nonempty host names")
  })
  let l = config.limits
  case
    config.deadline_ms > 0
    && config.connect_ms > 0
    && l.connections > 0
    && l.per_origin > 0
    && l.streams_per_connection > 0
    && l.active > 0
    && l.waiting >= 0
    && l.request_bytes >= 0
    && l.head_bytes > 0
    && l.header_count > 0
    && l.chunk_bytes > 0
    && l.queue_bytes >= l.chunk_bytes
    && l.collect_bytes >= 0
  {
    True -> Ok(config)
    False ->
      Error(
        "timeouts and capacities must be positive; queue must fit one chunk",
      )
  }
}

/// Observed transport; offline sessions do not claim negotiation.
pub type Negotiated {
  H1
  H2
  Offline
}
