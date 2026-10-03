//// Starts HTTP clients on Gun and sends requests through them.
////
//// ```gleam
//// import gleam/http/request
//// import http_gun
//// import http_gun/config
////
//// pub fn main() {
////   let assert Ok(client) = http_gun.start(config.default())
////   let assert Ok(req) = request.to("https://example.com/data")
////   let result = http_gun.send(client, request.set_body(req, <<>>))
////   http_gun.stop(client)
////   result
//// }
//// ```
////
//// There is one function per operation: `send` collects a response into
//// `Buffered`, `open` and `with_response` stream an owned `body.Body`, and
//// `batch` runs many requests with bounded concurrency. Non-2xx statuses are
//// response data. The client performs no retries, redirects or
//// decompression.
////
//// ## Client views
////
//// Per-call settings live on the client handle. Each `with_*` view returns a
//// new handle over the same pool, and every operation honours it:
////
//// ```gleam
//// let stream =
////   client
////   |> http_gun.with_timeout(config.Infinity)   // a long-lived SSE stream
////   |> http_gun.with_correlation(order)
//// ```
////
//// `with_timeout` and `with_deadline` replace the client's request timeout,
//// shorter or longer; the connect, pool and idle timeouts still apply.
//// `with_destination` can only narrow the destinations the client admits.
//// A client that serves several tenants admits the union of their
//// destinations, which any call holding the handle without a view reaches;
//// `config.require_view_destination` makes such a call fail closed with
//// `ViewDestinationRequired`. Only a view policy that narrows the client's
//// destinations satisfies it; a policy that only tightens the plaintext rule
//// does not, so a library tightening the scheme keeps the requirement.
////
//// A library that receives a view reads the caller's correlation with
//// `correlation(client)` and copies it into its own events, so one
//// `with_correlation` by the caller tags both packages' events.
////
//// ## Lifecycle
////
//// `start` links a client to the caller. Under a supervisor, use
//// `supervised(config, name)`; `named(name)` returns a handle that keeps
//// working across restarts. During a restart, calls fail with `ClientClosed`
//// and `NotSent`. `stop` refuses new work, lets open responses finish within
//// the shutdown timeout, then cancels them.
////
//// `http_gun/testing` and `http_gun/cassette` start offline and recording
//// clients of the same `Client` type.

import gleam/erlang/process
import gleam/http/request.{type Request}
import gleam/http/response.{type Response}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/otp/supervision
import gleam/result
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/destination
import http_gun/error
import http_gun/internal/batch
import http_gun/internal/bridge
import http_gun/internal/owner
import http_gun/internal/pool
import http_gun/internal/settings
import http_gun/redaction
import sinal/correlation.{type Correlation}

/// A shared client handle: the pool it sends through and the view settings
/// of this handle. Copy it freely.
pub type Client =
  pool.Client

/// The messages a supervised client's process receives; name it with
/// `process.new_name` for `supervised` and `named`.
pub type Message =
  pool.Message

pub type Failure =
  error.Failure

/// A collected response. Read fields by label; it may gain fields.
pub type Buffered {
  Buffered(
    response: Response(BitArray),
    trailers: List(#(String, String)),
    protocol: config.Negotiated,
    /// True only under `with_body_limit(_, _, Truncate)` when the body
    /// exceeded its limit: the body holds the first `limit` bytes and the
    /// trailers are empty.
    truncated: Bool,
  )
}

/// Current pool counters. Read fields by label; it may gain fields.
pub type Stats {
  Stats(connections: Int, open_bodies: Int, queued_requests: Int)
}

/// What `send` does when a response body exceeds its limit.
pub type Overflow {
  /// Close the body and fail with `LimitExceeded(ResponseBodyBytes, ..)`;
  /// `error.status` and `error.headers` return the response status and its
  /// headers, such as `retry-after`.
  Fail
  /// Close the body and return the status, headers and the first `limit`
  /// bytes, with `Buffered.truncated` set and no trailers.
  Truncate
}

/// Why a client did not start.
pub type StartError {
  InvalidConfig(config.ConfigError)
  /// The scripted exchange at this position has a status outside 200..599 or
  /// a body that is not whole bytes.
  InvalidScript(position: Int)
  /// The script exceeds its 16 MiB budget.
  ScriptTooLarge(limit: Int, observed: Int)
  /// The Gun application or the client process failed to start.
  StartFailed
}

pub fn describe_start_error(problem: StartError) -> String {
  case problem {
    InvalidConfig(config_error) ->
      "invalid configuration: " <> config.describe_error(config_error)
    InvalidScript(position) ->
      "invalid scripted exchange at position " <> int.to_string(position)
    ScriptTooLarge(limit, observed) ->
      "script of "
      <> int.to_string(observed)
      <> " bytes exceeds its limit of "
      <> int.to_string(limit)
    StartFailed -> "the client process failed to start"
  }
}

/// Validate the configuration, then start a client with its own connection
/// pool, linked to the caller.
pub fn start(settings: config.Config) -> Result(Client, StartError) {
  use settings <- result.try(
    config.validate(settings) |> result.map_error(InvalidConfig),
  )
  pool.start(settings, pool.Live)
  |> result.map(fn(started) { started.data })
  |> result.replace_error(StartFailed)
}

/// A child specification for a supervisor. The client registers under
/// `name`, so `named(name)` reaches it across restarts. An invalid
/// configuration fails the child's start.
///
/// ```gleam
/// let name = process.new_name("http_client")
/// let assert Ok(_) =
///   static_supervisor.new(static_supervisor.OneForOne)
///   |> static_supervisor.add(http_gun.supervised(config.default(), name))
///   |> static_supervisor.start
/// let client = http_gun.named(name)
/// ```
pub fn supervised(
  settings: config.Config,
  name: process.Name(Message),
) -> supervision.ChildSpecification(Client) {
  supervision.worker(fn() {
    case config.validate(settings) {
      Error(problem) -> Error(actor.InitFailed(config.describe_error(problem)))
      Ok(settings) -> pool.start_named(settings, name)
    }
  })
}

/// The handle of the client registered under `name` by `supervised`. Pure:
/// it does not check that the client is running.
pub fn named(name: process.Name(Message)) -> Client {
  pool.named(name)
}

/// Refuse new requests, fail queued ones with `ClientClosed` and `NotSent`,
/// let open responses finish within the shutdown timeout, then cancel them
/// and close every connection. Returns when the client has stopped;
/// stopping a stopped client returns at once. Meant for clients from
/// `start`: a supervisor restarts a supervised client that stops.
pub fn stop(client: Client) -> Nil {
  pool.stop(client)
}

/// Send a request and collect its response, up to the body limit. An
/// oversized body fails with `LimitExceeded(ResponseBodyBytes, ..)`, the
/// response status and its headers, unless the view chose `Truncate`. Every
/// failure after the head arrived keeps the status (`error.status`) and the
/// headers after the client's redaction (`error.headers`). The body is closed
/// on every path.
pub fn send(
  client: Client,
  req: Request(BitArray),
) -> Result(Buffered, Failure) {
  collect(client, req, fn(_) { Ok(Nil) })
}

fn collect(
  client: Client,
  req: Request(BitArray),
  charge: fn(Int) -> Result(Nil, Failure),
) -> Result(Buffered, Failure) {
  use pool.Opened(response, #(limit, truncate), redact) <- result.try(pool.open(
    client,
    req,
  ))
  bridge.scoped(
    fn() {
      use #(bytes, trailers, truncated) <- result.try(
        owner.collect(response.body, limit, truncate, charge)
        |> result.map_error(fn(failure) {
          // The head had arrived: keep the headers a caller decides on.
          case error.status(failure) {
            Some(_) ->
              error.with_headers(
                failure,
                redaction.headers(redact, response.headers),
              )
            None -> failure
          }
        }),
      )
      Ok(Buffered(
        response.set_body(response, bytes),
        trailers,
        body.protocol(response.body),
        truncated,
      ))
    },
    fn() { owner.close(response.body) },
  )
}

/// Open a response whose body the calling process reads. Close the body when
/// done, even after reading it to the end; prefer `with_response` when the
/// response fits inside one callback.
pub fn open(
  client: Client,
  req: Request(BitArray),
) -> Result(Response(body.Body), Failure) {
  pool.open(client, req) |> result.map(fn(opened) { opened.response })
}

/// Open a response, run `run` with it and close the body when `run` returns
/// or raises. `on_failure` maps an opening failure into the callback's error
/// type:
///
/// ```gleam
/// use response <- http_gun.with_response(client, req, AppHttpError)
/// read_events(response.body)
/// ```
pub fn with_response(
  client: Client,
  req: Request(BitArray),
  on_failure: fn(Failure) -> e,
  run: fn(Response(body.Body)) -> Result(a, e),
) -> Result(a, e) {
  case open(client, req) {
    Error(failure) -> Error(on_failure(failure))
    Ok(response) ->
      bridge.scoped(fn() { run(response) }, fn() { body.close(response.body) })
  }
}

/// Run at most `concurrency` requests at once, 1 to 1,024, over at most
/// 10,000 requests. Results keep input order, and a failure occupies only its
/// own position. Bodies retained across results are bounded by
/// `config.with_max_batch_bytes`: once reached, the response being collected
/// fails and requests not yet sent fail with `LimitExceeded(BatchBytes, ..)`
/// and `NotSent`.
pub fn batch(
  client: Client,
  requests: List(Request(BitArray)),
  concurrency: Int,
) -> Result(List(Result(Buffered, Failure)), Failure) {
  let limit = case pool.settings(client) {
    Ok(current) -> current.limits.batch_bytes
    // A closed client fails every request on its own.
    Error(_) -> 0
  }
  let counter = bridge.counter_new()
  batch.run(requests, concurrency, fn(req) {
    case bridge.counter_add(counter, 0) {
      total if total > limit && limit > 0 ->
        Error(error.new(
          error.LimitExceeded(error.BatchBytes, limit, total),
          error.NotSent,
        ))
      _ ->
        collect(client, req, fn(bytes) {
          case bridge.counter_add(counter, bytes) {
            total if total > limit && limit > 0 ->
              Error(error.new(
                error.LimitExceeded(error.BatchBytes, limit, total),
                error.MaybeSent,
              ))
            _ -> Ok(Nil)
          }
        })
    }
  })
}

/// Read the pool's counters. Holds no request history or credentials.
pub fn stats(client: Client) -> Result(Stats, Failure) {
  pool.stats(client)
  |> result.map(fn(counts) { Stats(counts.0, counts.1, counts.2) })
}

/// Bound each request made through this view from admission to its last
/// byte, replacing the client's request timeout, shorter or longer.
/// `config.Infinity` lifts the bound for a long-lived stream; the connect,
/// pool and idle timeouts still apply.
pub fn with_timeout(client: Client, timeout: config.Timeout) -> Client {
  let view = pool.view(client)
  pool.with_view(client, pool.View(..view, timeout: Some(bound(timeout))))
}

/// End every request made through this view by an absolute deadline shared
/// across calls. It replaces the client's request timeout; combined with
/// `with_timeout`, the earlier of the two applies.
pub fn with_deadline(client: Client, deadline: deadline.Deadline) -> Client {
  let view = pool.view(client)
  pool.with_view(
    client,
    pool.View(
      ..view,
      deadline: Some(
        bridge.now() + settings.milliseconds(deadline.remaining(deadline)),
      ),
    ),
  )
}

/// Replace the client's idle timeout for this view: the longest gap without
/// bytes while the response's owner waits for its head or reads its body.
/// Use it for a model that thinks before its first token, or a stream with
/// sparse keepalives.
pub fn with_idle_timeout(client: Client, timeout: config.Timeout) -> Client {
  let view = pool.view(client)
  pool.with_view(client, pool.View(..view, idle: Some(bound(timeout))))
}

/// Cancel unfinished requests made through this view when `token` is
/// cancelled. Cancellation never enters cassette matching.
pub fn with_cancellation(client: Client, token: cancellation.Token) -> Client {
  let view = pool.view(client)
  pool.with_view(client, pool.View(..view, token: Some(token)))
}

/// Collect at most `bytes` of each response body in `send` and `batch`
/// through this view, replacing `config.with_max_response_body_bytes`, and
/// choose what happens past the limit. A negative limit fails each request
/// with `InvalidRequest(InvalidBodyLimit)` before it is sent.
pub fn with_body_limit(
  client: Client,
  bytes: Int,
  overflow: Overflow,
) -> Client {
  let view = pool.view(client)
  pool.with_view(
    client,
    pool.View(..view, body_limit: Some(#(bytes, overflow == Truncate))),
  )
}

/// Narrow the destinations of this view: a request must satisfy the client's
/// policy and every policy added this way, including the addresses of a
/// pooled connection it would reuse. A view can never widen what the client
/// admits; host name resolution stays the client's.
///
/// A client configured with `config.require_view_destination` refuses
/// requests through a view unless one of its policies chooses a destination:
/// it sets `destination.only_hosts`, or it refuses an address class the
/// client admits. A policy that admits everything the client admits and only
/// tightens `destination.with_plaintext` chooses none, so a library that
/// tightens the scheme on a caller's view never lifts the application's
/// requirement:
///
/// ```gleam
/// // A library: tightens the scheme, chooses no destination.
/// let scheme =
///   destination.default()
///   |> destination.allow_loopback
///   |> destination.allow_private
///   |> destination.with_plaintext(destination.PlaintextToLoopbackOnly)
/// client |> http_gun.with_destination(scheme)
/// ```
pub fn with_destination(client: Client, policy: destination.Policy) -> Client {
  let view = pool.view(client)
  pool.with_view(
    client,
    pool.View(..view, policies: list.append(view.policies, [policy])),
  )
}

/// Tag the lifecycle events of requests made through this view with the
/// caller's correlation, under the `correlation` metadata key, so they join
/// the events of other packages working on the same unit. Every request
/// still gets its own `request_id`. A later call replaces the correlation.
pub fn with_correlation(client: Client, correlation: Correlation) -> Client {
  pool.with_correlation(client, correlation)
}

/// The correlation this view tags its events with, set by
/// `with_correlation`, or `None`. A library that receives a caller's view
/// reads the caller's correlation here and copies it into its own
/// telemetry, instead of asking the caller to pass it twice:
///
/// ```gleam
/// let correlation = http_gun.correlation(client)
/// ```
pub fn correlation(client: Client) -> Option(Correlation) {
  pool.view(client).correlation
}

fn bound(timeout: config.Timeout) -> settings.Bound {
  case timeout {
    config.After(timeout) -> settings.Within(settings.milliseconds(timeout))
    config.Infinity -> settings.Unbounded
  }
}
