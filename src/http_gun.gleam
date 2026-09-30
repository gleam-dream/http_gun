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
    error.Failure(error.ConnectionFailed, error.NotSubmitted)
  })
}

pub fn child(
  settings: config.Config,
) -> supervision.ChildSpecification(Client) {
  supervision.worker(fn() { pool.start(settings) })
}

pub fn stop(client: Client) -> Result(Nil, Failure) {
  pool.stop(client)
}

pub fn open(
  client: Client,
  req: request.Request(BitArray),
) -> Result(response.Response(body.Body), Failure) {
  pool.open(client, req)
}

pub fn with_response(
  client: Client,
  req: request.Request(BitArray),
  run: fn(response.Response(body.Body)) -> value,
) -> Result(value, Failure) {
  use response <- result.try(open(client, req))
  Ok(
    bridge.scoped(fn() { run(response) }, fn() {
      let _ = body.close(response.body)
      Nil
    }),
  )
}

pub fn send(
  client: Client,
  req: request.Request(BitArray),
) -> Result(Buffered, Failure) {
  with_response(client, req, fn(response) {
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

pub fn snapshot(client: Client) -> Result(Stats, Failure) {
  pool.snapshot(client)
}
