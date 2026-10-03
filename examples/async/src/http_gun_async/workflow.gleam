//// Ordinary REST and streaming workflows using public HTTP Gun imports.
////
//// Per-call settings are client views: each `http_gun.with_*` returns a new
//// handle over the same pool, so one shared client serves short REST calls,
//// long downloads and grouped requests alike.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/result
import http_gun
import http_gun/body
import http_gun/config
import http_gun/deadline
import http_gun/error

pub type AppError {
  Http(error.Failure)
}

/// One REST call bounded at 2 s, retried at most twice when HTTP Gun says a
/// retry is safe. HTTP Gun itself never retries: `is_retryable` admits a
/// failure that may have reached the server only for an idempotent method.
pub fn rest(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(http_gun.Buffered, error.Failure) {
  let client = client |> http_gun.with_timeout(config.Milliseconds(2000))
  attempt(client, req, 2)
}

fn attempt(
  client: http_gun.Client,
  req: request.Request(BitArray),
  retries: Int,
) -> Result(http_gun.Buffered, error.Failure) {
  case http_gun.send(client, req) {
    Ok(reply) -> Ok(reply)
    Error(failure) ->
      case
        retries > 0 && error.is_retryable(failure, idempotent: idempotent(req))
      {
        True -> attempt(client, req, retries - 1)
        False -> Error(failure)
      }
  }
}

fn idempotent(req: request.Request(BitArray)) -> Bool {
  case req.method {
    http.Get | http.Head | http.Put | http.Delete | http.Options -> True
    _ -> False
  }
}

/// A long download on the shared client: the view replaces the client's
/// request timeout with a deliberately chosen, longer finite one.
/// `with_response` closes the body on every path and maps an opening failure
/// into the application's error type.
pub fn download(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(Int, AppError) {
  let client = client |> http_gun.with_timeout(config.Milliseconds(300_000))
  use reply <- http_gun.with_response(client, req, Http)
  count(reply.body, 0)
}

fn count(source: body.Body, total: Int) -> Result(Int, AppError) {
  // `next` waits for bytes; the request and idle timeouts bound the wait.
  use event <- result.try(body.next(source) |> result.map_error(Http))
  case event {
    body.End(_) -> Ok(total)
    body.Chunk(bytes) -> count(source, total + bit_array.byte_size(bytes))
  }
}

/// Two requests that share one 2 s budget: the second gets what the first
/// left over.
pub fn rest_pair(
  client: http_gun.Client,
  first: request.Request(BitArray),
  second: request.Request(BitArray),
) -> Result(#(http_gun.Buffered, http_gun.Buffered), AppError) {
  let client = client |> http_gun.with_deadline(deadline.after(2000))
  use one <- result.try(http_gun.send(client, first) |> result.map_error(Http))
  use two <- result.try(http_gun.send(client, second) |> result.map_error(Http))
  Ok(#(one, two))
}

/// What the application does about a failure, from its closed `Kind`. The
/// match is exhaustive and keeps compiling across HTTP Gun minor releases.
pub fn advice(problem: AppError) -> String {
  let Http(failure) = problem
  case error.kind(failure) {
    error.InvalidInput -> "fix the request"
    error.Refused -> "the destination policy refused the host"
    error.Unavailable -> "the client is busy or restarting; try again later"
    error.Network -> "the network failed"
    error.TimedOut -> "the server was too slow"
    error.TooLarge -> "the response was larger than allowed"
    error.CancelledLocally -> "the request was cancelled here"
    error.Misuse -> "the body was read from the wrong process"
    error.Playback -> "no scripted exchange matched"
  }
}
