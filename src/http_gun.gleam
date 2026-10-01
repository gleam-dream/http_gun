//// Generic HTTP on Gun. Start once, share the client, own each response body.

import gleam/http/request
import gleam/http/response
import gleam/otp/supervision
import gleam/result
import http_gun/body
import http_gun/config
import http_gun/error
import http_gun/internal/batch
import http_gun/internal/bridge
import http_gun/internal/pool
import http_gun/request_options
import http_gun/telemetry

pub type Client =
  pool.Client

pub type Failure =
  error.Failure

pub type Buffered {
  Buffered(
    response: response.Response(BitArray),
    trailers: List(#(String, String)),
    protocol: config.Negotiated,
  )
}

/// Validate pure settings, then start a linked client with its own connection pool.
/// Share the returned capability between callers; stop it or supervise it explicitly.
pub fn start(settings: config.Config) -> Result(Client, Failure) {
  use _ <- result.try(
    config.validate(settings)
    |> result.map_error(fn(message) {
      error.Failure(error.InvalidConfig(message), error.NotSubmitted)
    }),
  )
  pool.start(settings)
  |> result.map(fn(started) { started.data })
  |> result.map_error(fn(_) {
    error.Failure(
      error.ConnectionFailed(error.UnknownTransport),
      error.NotSubmitted,
    )
  })
}

/// Build a standard OTP worker specification. Invalid settings fail child startup.
/// A restart creates a new client capability; previous handles remain closed.
pub fn child(
  settings: config.Config,
) -> supervision.ChildSpecification(Client) {
  supervision.worker(fn() { pool.start(settings) })
}

/// Cancel outstanding local work and close this client's connections.
/// Does not stop the shared Gun/SSL applications or guarantee remote cancellation.
pub fn stop(client: Client) -> Result(Nil, Failure) {
  pool.stop(client)
}

/// Inspect this capability's immutable startup request ceiling in milliseconds.
/// Pure: also returns the original policy for a stopped or stale capability;
/// it does not check liveness. A supervisor restart supplies a new capability.
/// Each request uses the earlier of this ceiling from call entry and its
/// supplied absolute monotonic deadline. Read waits do not change that budget.
pub fn request_ceiling_ms(client: Client) -> Int {
  pool.config(client).deadline_ms
}

/// Open an explicitly owned response. The calling process owns body consumption.
/// Copies share one cursor; close the body even after completion. Prefer a scope
/// when the response lifetime fits inside one callback.
pub fn open(
  client: Client,
  req: request.Request(BitArray),
) -> Result(response.Response(body.Body), Failure) {
  pool.open(client, req)
}

/// Open with optional deadline and cancellation, retaining the client's policies.
/// The calling process owns consumption; close the returned body explicitly.
pub fn open_with_options(
  client: Client,
  req: request.Request(BitArray),
  options: request_options.Options,
) -> Result(response.Response(body.Body), Failure) {
  pool.open_with_options(client, req, options)
}

/// Run a callback and close the body on return or exception.
/// The outer Result reports opening failure; the callback keeps its own type.
/// Use try_with_response when the callback already returns a Result.
pub fn with_response(
  client: Client,
  req: request.Request(BitArray),
  run: fn(response.Response(body.Body)) -> value,
) -> Result(value, Failure) {
  with_response_with_options(client, req, request_options.default(), run)
}

/// Scoped streaming with execution controls. Always closes on scope exit.
pub fn with_response_with_options(
  client: Client,
  req: request.Request(BitArray),
  options: request_options.Options,
  run: fn(response.Response(body.Body)) -> value,
) -> Result(value, Failure) {
  use response <- result.try(open_with_options(client, req, options))
  Ok(
    bridge.scoped(fn() { run(response) }, fn() {
      let _ = body.close(response.body)
      Nil
    }),
  )
}

/// Run a fallible consumer and always close its body on scope exit.
/// Opening failures pass through on_http_error; the callback maps its own read
/// and application errors. Exceptions still propagate after cleanup.
pub fn try_with_response(
  client: Client,
  req: request.Request(BitArray),
  on_http_error: fn(Failure) -> app_error,
  consume: fn(response.Response(body.Body)) -> Result(value, app_error),
) -> Result(value, app_error) {
  with_response(client, req, consume)
  |> result.map_error(on_http_error)
  |> result.flatten
}

/// Fallible scoped streaming with execution controls and caller-owned errors.
pub fn try_with_response_with_options(
  client: Client,
  req: request.Request(BitArray),
  options: request_options.Options,
  on_http_error: fn(Failure) -> app_error,
  consume: fn(response.Response(body.Body)) -> Result(value, app_error),
) -> Result(value, app_error) {
  with_response_with_options(client, req, options, consume)
  |> result.map_error(on_http_error)
  |> result.flatten
}

/// Collect response bytes and trailers using the same owned streaming path.
/// Enforces the client collection limit; always closes on success or failure.
/// HTTP status codes, including non-2xx statuses, remain response data.
pub fn send(
  client: Client,
  req: request.Request(BitArray),
) -> Result(Buffered, Failure) {
  send_with_options(client, req, request_options.default())
}

/// Collect the owned stream within the client collection limit and request budget.
/// Failures and scope exit close the body. Status codes remain response data.
pub fn send_with_options(
  client: Client,
  req: request.Request(BitArray),
  options: request_options.Options,
) -> Result(Buffered, Failure) {
  with_response_with_options(client, req, options, fn(response) {
    use collected <- result.try(body.collect(
      response.body,
      pool.config(client).limits.collect_bytes,
    ))
    Ok(Buffered(
      response.set_body(response, collected.bytes),
      collected.trailers,
      body.protocol(response.body),
    ))
  })
  |> result.flatten
}

/// Run at most concurrency requests at once; results retain input order.
/// A failure occupies its own result position and never replays other work.
pub fn batch(
  client: Client,
  requests: List(request.Request(BitArray)),
  concurrency: Int,
) -> Result(List(Result(Buffered, Failure)), Failure) {
  batch.run(requests, concurrency, fn(req) { send(client, req) })
}

/// Finite operational counters; contains no request history or credentials.
pub type Stats =
  pool.Stats

/// Read current pool counters without retaining request history.
pub fn snapshot(client: Client) -> Result(Stats, Failure) {
  pool.snapshot(client)
}

/// Create a client view carrying an opaque observation correlation for subsequent
/// calls, including a batch. It shares the same pool, policy and lifetime: stopping
/// either view stops that client. Every invocation still gets its own request_id.
/// This is pure and does not enable observations or alter HTTP/cassette matching.
pub fn with_correlation(client: Client, id: telemetry.Id) -> Client {
  pool.with_correlation(client, id)
}
