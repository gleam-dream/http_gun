//// Configures a client: destinations, protocol, TLS trust, timeouts, size
//// limits, redaction and observations.
////
//// Start from `default()` and change only what you need:
////
//// ```gleam
//// let settings =
////   config.default()
////   |> config.allow_loopback
////   |> config.with_protocol(config.PreferHttp2)
////   |> config.with_request_timeout(config.After(duration.seconds(10)))
//// let assert Ok(client) = http_gun.start(settings)
//// ```
////
//// Every timeout is a `gleam/time/duration.Duration`; a timeout that may be
//// lifted takes a `Timeout`, where `Infinity` must be chosen explicitly.
//// HTTP Gun keeps whole milliseconds, rounding a sub-millisecond remainder
//// away from zero.
////
//// A `Config` is opaque, so a new option never breaks your code. `validate`
//// checks it without starting processes; `http_gun.start` validates it too
//// and returns the same `ConfigError`. A configured client identity contains
//// private key material; never log arbitrary configuration values.
////
//// ## Defaults
////
//// | Setting | Default | Setter |
//// | --- | --- | --- |
//// | destinations | public addresses only | `allow_loopback`, `with_destination` |
//// | destination on every view | not required | `require_view_destination` |
//// | protocol | HTTP/1.1 | `with_protocol` |
//// | TLS client identity | none | `with_client_identity` |
//// | TLS trust | system CA store, peer and host name verified | `with_trust` |
//// | connect, including DNS and TLS | `duration.seconds(5)` | `with_connect_timeout` |
//// | waiting for a pooled connection | `duration.seconds(5)` | `with_pool_timeout` |
//// | request, admission to last byte | `After(duration.seconds(30))` | `with_request_timeout` |
//// | idle read, no bytes while reading | `After(duration.seconds(30))` | `with_idle_timeout` |
//// | idle pooled connection | `duration.seconds(60)` | `with_connection_idle_timeout` |
//// | draining on `stop` | `duration.seconds(5)` | `with_shutdown_timeout` |
//// | connections / per origin | 16 / 4 | `with_max_connections`, `with_max_connections_per_origin` |
//// | HTTP/2 streams per connection | 100 | `with_max_streams_per_connection` |
//// | open response bodies | 128 | `with_max_open_bodies` |
//// | queued requests | 128 | `with_max_queued_requests` |
//// | request body | 1 MiB | `with_max_request_body_bytes` |
//// | header bytes / count | 16 KiB / 100 | `with_max_header_bytes`, `with_max_header_count` |
//// | buffered response bytes | 128 KiB | `with_max_buffered_bytes` |
//// | collected response body (`send`) | 8 MiB | `with_max_response_body_bytes` |
//// | bytes retained by one `batch` | 64 MiB | `with_max_batch_bytes` |
//// | redaction | credential headers | `with_redaction` |
//// | observations | `sinal.emit`, which follows the application's routes | `with_observations`, `without_observations` |
//// | client label in events | none | `with_label` |

import gleam/bit_array
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/time/duration.{type Duration}
import http_gun/client_identity
import http_gun/destination
import http_gun/internal/settings.{type Settings, Limits, Settings}
import http_gun/redaction
import sinal/forwarder

/// Client settings. Build with `default()` and the `with_*` functions.
pub type Config =
  Settings

/// Which HTTP versions a client negotiates.
pub type Protocol {
  /// HTTP/1.1 only.
  Http1
  /// HTTP/2 over TLS when the server offers it through ALPN, else HTTP/1.1.
  /// Plain-text connections use HTTP/1.1.
  PreferHttp2
  /// HTTP/2 only; a server that negotiates HTTP/1.1 fails the connection.
  RequireHttp2
}

/// Which certificate authorities verify a TLS server. Every choice verifies
/// the peer and its host name.
pub type Trust {
  SystemTrust
  /// A PEM file of CA certificates, replacing system trust.
  CustomCa(path: String)
  /// DER-encoded CA certificates, replacing system trust without file IO.
  Anchors(certificates: List(BitArray))
}

/// A time bound that may be lifted. `Infinity` lifts it and must be chosen
/// explicitly.
pub type Timeout {
  After(Duration)
  Infinity
}

/// The protocol a response used. Scripted and cassette responses report
/// `Offline`.
pub type Negotiated {
  H1
  H2
  Offline
}

/// Resolves a host name for a new connection, replacing DNS, for example in
/// tests. It receives the host and the time left in the connect timeout, runs in an isolated worker, and returns the complete A/AAAA
/// answer. Every address is checked against the destination policy; an
/// exception or an empty answer fails closed.
pub type Resolver =
  fn(String, Duration) -> Result(List(destination.Address), Nil)

/// A setting, as `ConfigError` names it.
pub type Setting {
  ConnectTimeout
  PoolTimeout
  RequestTimeout
  IdleTimeout
  ConnectionIdleTimeout
  ShutdownTimeout
  MaxConnections
  MaxConnectionsPerOrigin
  MaxStreamsPerConnection
  MaxOpenBodies
  MaxQueuedRequests
  MaxRequestBodyBytes
  MaxHeaderBytes
  MaxHeaderCount
  MaxBufferedBytes
  MaxResponseBodyBytes
  MaxBatchBytes
}

/// Why a configuration is invalid.
pub type ConfigError {
  /// A capacity is out of range: it must be positive; queued requests,
  /// request body and response body limits may also be zero.
  OutOfRange(setting: Setting, value: Int)
  /// A timeout is out of range, in HTTP Gun's whole-millisecond precision:
  /// it must be positive; the shutdown timeout may also be zero.
  TimeoutOutOfRange(setting: Setting, value: Duration)
  /// `Anchors([])` trusts nothing.
  EmptyTrustAnchors
  /// A trust anchor is empty or not whole bytes.
  InvalidTrustAnchor
  /// A `destination.only_hosts` entry is malformed.
  InvalidAllowedHost(entry: String)
}

/// Public destinations only, HTTP/1.1, verified TLS with system trust, and
/// the bounds in the module's defaults table. Starts nothing.
pub fn default() -> Config {
  Settings(
    protocol: settings.Http1,
    trust: settings.SystemTrust,
    client_identity: None,
    connect_timeout: 5000,
    pool_timeout: 5000,
    request_timeout: settings.Within(30_000),
    idle_timeout: settings.Within(30_000),
    connection_idle_timeout: 60_000,
    shutdown_timeout: 5000,
    limits: Limits(
      connections: 16,
      per_origin: 4,
      streams_per_connection: 100,
      open_bodies: 128,
      queued_requests: 128,
      request_body_bytes: 1_048_576,
      header_bytes: 16_384,
      header_count: 100,
      buffered_bytes: 131_072,
      response_body_bytes: 8_388_608,
      batch_bytes: 67_108_864,
    ),
    observations: settings.Emit,
    label: None,
    destination: destination.default(),
    view_destination_required: False,
    resolver: None,
    redaction: redaction.default(),
  )
}

/// Also admit loopback destinations (127.0.0.0/8 and ::1), for a local server
/// in tests or development. Every other destination setting is kept.
pub fn allow_loopback(config: Config) -> Config {
  Settings(
    ..config,
    destination: destination.allow_loopback(config.destination),
  )
}

/// Replace the destination policy.
pub fn with_destination(config: Config, policy: destination.Policy) -> Config {
  Settings(..config, destination: policy)
}

/// Refuse every request whose client view has not chosen a destination with
/// `http_gun.with_destination`, failing it with `ViewDestinationRequired` and
/// `NotSent` before it is validated, resolved or matched. The client's own
/// policy then only bounds what views may narrow to: a view still narrows
/// and never widens it.
///
/// A view chooses a destination when one of its policies sets
/// `destination.only_hosts` or refuses an address class this client admits.
/// A plaintext rule never counts: a library that only tightens
/// `destination.with_plaintext` on a caller's view leaves the requirement in
/// force.
///
/// A multi-tenant client must admit the union of its tenants' destinations,
/// for example public addresses and loopback. Without this setting, a call
/// that skips the tenant's view reaches that union; with it, the call fails
/// closed. The check applies to live, recording and playback clients alike,
/// so a cassette test catches a call that skips the view.
///
/// ```gleam
/// let assert Ok(client) =
///   config.default()
///   |> config.allow_loopback
///   |> config.require_view_destination
///   |> http_gun.start
/// let public = client |> http_gun.with_destination(destination.default())
/// ```
pub fn require_view_destination(config: Config) -> Config {
  Settings(..config, view_destination_required: True)
}

/// Resolve host names with `resolver` instead of DNS.
pub fn with_resolver(config: Config, resolver: Resolver) -> Config {
  Settings(..config, resolver: Some(resolver))
}

pub fn with_protocol(config: Config, protocol: Protocol) -> Config {
  Settings(..config, protocol: case protocol {
    Http1 -> settings.Http1
    PreferHttp2 -> settings.PreferHttp2
    RequireHttp2 -> settings.RequireHttp2
  })
}

pub fn with_trust(config: Config, trust: Trust) -> Config {
  Settings(..config, trust: case trust {
    SystemTrust -> settings.SystemTrust
    CustomCa(path) -> settings.CustomCa(path)
    Anchors(certificates) -> settings.Anchors(certificates)
  })
}

/// Present this immutable identity when a TLS server requests client
/// authentication. Trust and hostname verification remain independent.
/// Every connection in this client uses the same snapshot, including reconnects.
/// Views cannot replace it. Rotate by starting a new client and draining/stopping
/// the old client; in-flight old-client exchanges retain their old identity.
/// The setter is pure. Plaintext connections send no identity material.
pub fn with_client_identity(
  config: Config,
  identity: client_identity.Identity,
) -> Config {
  Settings(..config, client_identity: Some(identity))
}

/// Choose what cassettes never store. See `http_gun/redaction`.
pub fn with_redaction(
  config: Config,
  redaction: redaction.Redaction,
) -> Config {
  Settings(..config, redaction:)
}

/// Hand lifecycle events to this forwarder instead of emitting them with
/// `sinal.emit`. By default HTTP Gun calls `sinal.emit`, so the events follow
/// the application's `forwarder.route` for `["http_gun"]`; without a route,
/// handlers run in HTTP Gun's pool and body processes.
pub fn with_observations(
  config: Config,
  target: forwarder.Forwarder,
) -> Config {
  Settings(..config, observations: settings.Forward(target))
}

/// Emit no lifecycle events from this client. A later `with_observations`
/// turns them back on.
///
/// A library that owns a private client may choose this so that its HTTP
/// stays out of the application's handlers. Prefer `with_label`: a labelled
/// client lets the application decide whether to watch or skip it.
pub fn without_observations(config: Config) -> Config {
  Settings(..config, observations: settings.Silent)
}

/// Name this client in every lifecycle event, as the metadata's `client`
/// field, so a handler that sees every client's events can tell them apart.
/// Unlabelled clients report `None`. The label is any text; it is not a
/// credential and is not stored in cassettes.
///
/// A library that starts its own private client should label it with the
/// library's name, for example `"warden"`.
pub fn with_label(config: Config, label: String) -> Config {
  Settings(..config, label: Some(label))
}

/// Bound resolving, connecting and the TLS handshake of each new connection,
/// together. Default 5 s.
pub fn with_connect_timeout(config: Config, timeout: Duration) -> Config {
  Settings(..config, connect_timeout: settings.milliseconds(timeout))
}

/// Bound the wait for a connection or stream from the pool, including an
/// HTTP/1.1 readiness check. A request that triggers a new connection is
/// bounded by the connect timeout instead. Default 5 s.
pub fn with_pool_timeout(config: Config, timeout: Duration) -> Config {
  Settings(..config, pool_timeout: settings.milliseconds(timeout))
}

/// Bound each request from admission to the last body byte. Default 30 s.
/// `http_gun.with_timeout` and `http_gun.with_deadline` replace it for one
/// client view, shorter or longer. `Infinity` lifts it; the connect, pool
/// and idle timeouts still apply.
pub fn with_request_timeout(config: Config, timeout: Timeout) -> Config {
  Settings(..config, request_timeout: bound(timeout))
}

/// Fail a response when no bytes arrive for this long while its owner waits
/// for the head or reads the body. A reader that pauses is not idle. Also
/// bounds a stalled socket write. Default 30 s; `http_gun.with_idle_timeout`
/// replaces it for one client view.
pub fn with_idle_timeout(config: Config, timeout: Timeout) -> Config {
  Settings(..config, idle_timeout: bound(timeout))
}

/// Close a pooled connection that has carried no request for this long.
/// Default 60 s.
pub fn with_connection_idle_timeout(
  config: Config,
  timeout: Duration,
) -> Config {
  Settings(..config, connection_idle_timeout: settings.milliseconds(timeout))
}

/// How long `http_gun.stop` lets open responses finish before cancelling
/// them. Zero cancels at once. Default 5 s.
pub fn with_shutdown_timeout(config: Config, timeout: Duration) -> Config {
  Settings(..config, shutdown_timeout: settings.milliseconds(timeout))
}

/// Connections across all origins. Default 16.
pub fn with_max_connections(config: Config, count: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, connections: count))
}

/// Connections to one scheme, host and port. Default 4.
pub fn with_max_connections_per_origin(config: Config, count: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, per_origin: count))
}

/// Concurrent HTTP/2 streams per connection, below the server's own limit.
/// Default 100.
pub fn with_max_streams_per_connection(config: Config, count: Int) -> Config {
  Settings(
    ..config,
    limits: Limits(..config.limits, streams_per_connection: count),
  )
}

/// Response bodies open at once; further requests queue. Default 128.
pub fn with_max_open_bodies(config: Config, count: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, open_bodies: count))
}

/// Requests waiting for capacity; beyond this a request fails with
/// `AdmissionFull`. Default 128.
pub fn with_max_queued_requests(config: Config, count: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, queued_requests: count))
}

/// Request body bytes. Default 1 MiB.
pub fn with_max_request_body_bytes(config: Config, bytes: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, request_body_bytes: bytes))
}

/// Header bytes (names plus values) of a request, a response head or its
/// trailers. Default 16 KiB.
pub fn with_max_header_bytes(config: Config, bytes: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, header_bytes: bytes))
}

/// Headers in a request, a response head or its trailers. Default 100.
pub fn with_max_header_count(config: Config, count: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, header_count: count))
}

/// Response bytes buffered between the network and a slow reader, which also
/// bounds one chunk. Default 128 KiB.
pub fn with_max_buffered_bytes(config: Config, bytes: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, buffered_bytes: bytes))
}

/// Body bytes that `send` and `batch` collect per response; a larger body
/// fails with `LimitExceeded(ResponseBodyBytes, ..)` and the response status.
/// `http_gun.with_body_limit` replaces it per view. Streaming reads are not
/// bounded by it. Default 8 MiB.
pub fn with_max_response_body_bytes(config: Config, bytes: Int) -> Config {
  Settings(
    ..config,
    limits: Limits(..config.limits, response_body_bytes: bytes),
  )
}

/// Body bytes that one `batch` call retains across its results. Once
/// reached, the response being collected fails and requests not yet sent
/// fail with `LimitExceeded(BatchBytes, ..)`. Default 64 MiB.
pub fn with_max_batch_bytes(config: Config, bytes: Int) -> Config {
  Settings(..config, limits: Limits(..config.limits, batch_bytes: bytes))
}

/// Check every setting without starting processes.
pub fn validate(config: Config) -> Result(Config, ConfigError) {
  use Nil <- result.try(case config.trust {
    settings.Anchors([]) -> Error(EmptyTrustAnchors)
    settings.Anchors(certificates) ->
      case
        list.all(certificates, fn(cert) {
          bit_array.bit_size(cert) > 0 && bit_array.bit_size(cert) % 8 == 0
        })
      {
        True -> Ok(Nil)
        False -> Error(InvalidTrustAnchor)
      }
    settings.SystemTrust | settings.CustomCa(_) -> Ok(Nil)
  })
  use _ <- result.try(
    destination.validate(config.destination)
    |> result.map_error(InvalidAllowedHost),
  )
  let timeouts = [
    #(ConnectTimeout, config.connect_timeout, 1),
    #(PoolTimeout, config.pool_timeout, 1),
    #(RequestTimeout, bound_value(config.request_timeout), 1),
    #(IdleTimeout, bound_value(config.idle_timeout), 1),
    #(ConnectionIdleTimeout, config.connection_idle_timeout, 1),
    #(ShutdownTimeout, config.shutdown_timeout, 0),
  ]
  use Nil <- result.try(
    case list.find(timeouts, fn(check) { check.1 < check.2 }) {
      Ok(#(setting, milliseconds, _)) ->
        Error(TimeoutOutOfRange(setting, duration.milliseconds(milliseconds)))
      Error(Nil) -> Ok(Nil)
    },
  )
  let l = config.limits
  let checks = [
    #(MaxConnections, l.connections, 1),
    #(MaxConnectionsPerOrigin, l.per_origin, 1),
    #(MaxStreamsPerConnection, l.streams_per_connection, 1),
    #(MaxOpenBodies, l.open_bodies, 1),
    #(MaxQueuedRequests, l.queued_requests, 0),
    #(MaxRequestBodyBytes, l.request_body_bytes, 0),
    #(MaxHeaderBytes, l.header_bytes, 1),
    #(MaxHeaderCount, l.header_count, 1),
    #(MaxBufferedBytes, l.buffered_bytes, 1),
    #(MaxResponseBodyBytes, l.response_body_bytes, 0),
    #(MaxBatchBytes, l.batch_bytes, 1),
  ]
  case list.find(checks, fn(check) { check.1 < check.2 }) {
    Ok(#(setting, value, _)) -> Error(OutOfRange(setting, value))
    Error(Nil) -> Ok(config)
  }
}

/// Describe a configuration error for logs.
pub fn describe_error(error: ConfigError) -> String {
  case error {
    OutOfRange(setting, value) ->
      setting_name(setting)
      <> " is out of range: "
      <> int.to_string(value)
      <> range_rule(setting)
    TimeoutOutOfRange(setting, value) ->
      setting_name(setting)
      <> " is out of range: "
      <> int.to_string(settings.milliseconds(value))
      <> " ms"
      <> range_rule(setting)
    EmptyTrustAnchors -> "trust anchors are empty"
    InvalidTrustAnchor -> "a trust anchor is empty or not whole bytes"
    InvalidAllowedHost(entry) -> "malformed allowed host entry: " <> entry
  }
}

fn range_rule(setting: Setting) -> String {
  case setting {
    ShutdownTimeout
    | MaxQueuedRequests
    | MaxRequestBodyBytes
    | MaxResponseBodyBytes -> " (must not be negative)"
    _ -> " (must be positive)"
  }
}

fn setting_name(setting: Setting) -> String {
  case setting {
    ConnectTimeout -> "connect timeout"
    PoolTimeout -> "pool timeout"
    RequestTimeout -> "request timeout"
    IdleTimeout -> "idle timeout"
    ConnectionIdleTimeout -> "connection idle timeout"
    ShutdownTimeout -> "shutdown timeout"
    MaxConnections -> "max connections"
    MaxConnectionsPerOrigin -> "max connections per origin"
    MaxStreamsPerConnection -> "max streams per connection"
    MaxOpenBodies -> "max open bodies"
    MaxQueuedRequests -> "max queued requests"
    MaxRequestBodyBytes -> "max request body bytes"
    MaxHeaderBytes -> "max header bytes"
    MaxHeaderCount -> "max header count"
    MaxBufferedBytes -> "max buffered bytes"
    MaxResponseBodyBytes -> "max response body bytes"
    MaxBatchBytes -> "max batch bytes"
  }
}

fn bound(timeout: Timeout) -> settings.Bound {
  case timeout {
    After(timeout) -> settings.Within(settings.milliseconds(timeout))
    Infinity -> settings.Unbounded
  }
}

fn bound_value(bound: settings.Bound) -> Int {
  case bound {
    settings.Within(ms) -> ms
    settings.Unbounded -> 1
  }
}
