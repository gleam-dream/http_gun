//// Ordinary REST and streaming workflows using public HTTP Gun imports.

import gleam/bit_array
import gleam/http/request
import gleam/int
import gleam/option.{Some}
import gleam/result
import http_gun
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun/request_options

pub type AppError {
  Http(error.Failure)
}

pub fn rest(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(http_gun.Buffered, error.Failure) {
  use budget <- result.try(deadline.after(2000))
  http_gun.send_with_options(
    client,
    req,
    request_options.Options(..request_options.default(), deadline: Some(budget)),
  )
}

// An estimate taken now, not a reservation. The actual HTTP call recomputes it.
pub fn estimate(client: http_gun.Client, budget: deadline.Deadline) -> Int {
  int.min(http_gun.request_ceiling_ms(client), deadline.remaining_ms(budget))
}

// Applications deliberately choose a finite longer ceiling at startup.
pub fn start_downloads() -> Result(http_gun.Client, error.Failure) {
  http_gun.start(config.Config(..config.default(), deadline_ms: 300_000))
}

pub fn download(
  client: http_gun.Client,
  req: request.Request(BitArray),
) -> Result(Int, AppError) {
  use budget <- result.try(deadline.after(300_000) |> result.map_error(Http))
  cancellation.try_with_token(Http, fn(token) {
    http_gun.try_with_response_with_options(
      client,
      req,
      request_options.Options(deadline: Some(budget), cancellation: Some(token)),
      Http,
      fn(reply) { count(reply.body, 0) },
    )
  })
}

fn count(source: body.Body, total: Int) -> Result(Int, AppError) {
  use event <- result.try(body.next(source, 1000) |> result.map_error(Http))
  case event {
    body.End(_) -> Ok(total)
    body.Chunk(bytes) -> count(source, total + bit_array.byte_size(bytes))
  }
}

pub fn rest_pair(
  client: http_gun.Client,
  first: request.Request(BitArray),
  second: request.Request(BitArray),
) -> Result(#(http_gun.Buffered, http_gun.Buffered), AppError) {
  cancellation.try_with_token(Http, fn(token) {
    let options =
      request_options.Options(
        ..request_options.default(),
        cancellation: Some(token),
      )
    use one <- result.try(
      http_gun.send_with_options(client, first, options)
      |> result.map_error(Http),
    )
    use two <- result.try(
      http_gun.send_with_options(client, second, options)
      |> result.map_error(Http),
    )
    Ok(#(one, two))
  })
}
