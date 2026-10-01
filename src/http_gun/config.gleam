/// Pure startup policy. All limits are checked before starting a client.
import gleam/option.{type Option, None}
import sinal/forwarder

pub type Protocol {
  Http1
  PreferHttp2
  RequireHttp2
}

pub type Trust {
  SystemTrust
  CustomCa(path: String)
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
  )
}

/// Finite H1 policy with verified system TLS trust and a 30-second request budget.
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
  )
}

/// Check supported policies and positive capacities without starting processes.
/// Returns the unchanged settings or a diagnostic for invalid configuration.
pub fn validate(config: Config) -> Result(Config, String) {
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
