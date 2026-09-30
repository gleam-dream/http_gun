//// Version 1 JSON codec. Dynamic decoding is confined to this boundary.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/result
import gleam/uri
import http_gun/error.{type Failure, Failure, NotSubmitted}
import http_gun/fixture

pub fn encode(exchanges: List(fixture.Exchange)) -> String {
  json.object([
    #("http_gun", json.int(1)),
    #("exchanges", json.array(exchanges, exchange_json)),
  ])
  |> json.to_string
}

pub fn parse(text: String) -> Result(List(fixture.Exchange), error.Reason) {
  let version = {
    use value <- decode.field("http_gun", decode.int)
    decode.success(value)
  }
  use version <- result.try(
    json.parse(text, version)
    |> result.map_error(fn(_) { error.FixtureCorrupt }),
  )
  case version {
    1 -> {
      let decoder = {
        use values <- decode.field("exchanges", decode.list(exchange_decoder()))
        decode.success(values)
      }
      json.parse(text, decoder)
      |> result.map_error(fn(_) { error.FixtureCorrupt })
    }
    other -> Error(error.FixtureVersion(other))
  }
}

pub fn exchange_json(exchange: fixture.Exchange) -> json.Json {
  json.object([
    #("request", request_json(exchange.request)),
    #("reply", reply_json(exchange.reply)),
  ])
}

pub fn request_json(req: request.Request(BitArray)) -> json.Json {
  let req = fixture.sanitise(req)
  json.object([
    #("url", json.string(uri.to_string(request.to_uri(req)))),
    #("method", json.string(http.method_to_string(req.method))),
    #("headers", headers_json(req.headers)),
    #("body", bytes_json(req.body)),
  ])
}

pub fn headers_json(headers: List(#(String, String))) -> json.Json {
  json.array(fixture.safe_headers(headers), fn(h) {
    json.array([h.0, h.1], json.string)
  })
}

pub fn bytes_json(bytes: BitArray) -> json.Json {
  json.object([
    #("bytes", json.int(bit_array.byte_size(bytes))),
    #("base64", json.string(bit_array.base64_encode(bytes, True))),
  ])
}

pub fn reply_json(reply: fixture.Reply) -> json.Json {
  case reply {
    fixture.Reject(failure) ->
      json.object([
        #("kind", json.string("reject")),
        #("failure", failure_json(failure)),
      ])
    fixture.Respond(response, ending) ->
      json.object([
        #("kind", json.string("response")),
        #("status", json.int(response.status)),
        #("headers", headers_json(response.headers)),
        #("chunks", json.array(response.body, bytes_json)),
        #("ending", ending_json(ending)),
      ])
  }
}

pub fn ending_json(ending: fixture.Ending) -> json.Json {
  case ending {
    fixture.Complete(trailers) ->
      json.object([
        #("kind", json.string("complete")),
        #("trailers", headers_json(trailers)),
      ])
    fixture.Failed(failure) ->
      json.object([
        #("kind", json.string("failed")),
        #("failure", failure_json(failure)),
      ])
    fixture.Cancelled -> json.object([#("kind", json.string("cancelled"))])
  }
}

pub fn failure_json(failure: Failure) -> json.Json {
  let #(tag, detail, count) = case failure.reason {
    error.InvalidConfig(text) -> #("invalid_config", text, 0)
    error.InvalidRequest(text) -> #("invalid_request", text, 0)
    error.ClientClosed -> #("client_closed", "", 0)
    error.AdmissionFull -> #("admission_full", "", 0)
    error.ConnectionFailed -> #("connection_failed", "", 0)
    error.RequestFailed -> #("request_failed", "", 0)
    error.DeadlineExceeded -> #("deadline", "", 0)
    error.ReadTimeout -> #("read_timeout", "", 0)
    error.ReadConflict -> #("read_conflict", "", 0)
    error.WrongOwner -> #("wrong_owner", "", 0)
    error.Closed -> #("closed", "", 0)
    error.LimitExceeded(kind, limit) -> #("limit", kind, limit)
    error.FixtureMissing -> #("fixture_missing", "", 0)
    error.FixtureCorrupt -> #("fixture_corrupt", "", 0)
    error.FixtureVersion(version) -> #("fixture_version", "", version)
    error.FixtureExhausted -> #("fixture_exhausted", "", 0)
    error.FixtureMismatch(position) -> #("fixture_mismatch", "", position)
    error.CaptureFailed(text) -> #("capture_failed", text, 0)
  }
  let evidence = case failure.evidence {
    error.NotSubmitted -> "not_submitted"
    error.MayHaveBeenSent -> "may_have_been_sent"
  }
  json.object([
    #("reason", json.string(tag)),
    #("detail", json.string(detail)),
    #("count", json.int(count)),
    #("evidence", json.string(evidence)),
  ])
}

fn exchange_decoder() -> decode.Decoder(fixture.Exchange) {
  use req <- decode.field("request", request_decoder())
  use reply <- decode.field("reply", reply_decoder())
  decode.success(fixture.Exchange(req, reply))
}

fn request_decoder() -> decode.Decoder(request.Request(BitArray)) {
  use url <- decode.field("url", decode.string)
  use method <- decode.field("method", decode.string)
  use headers <- decode.field("headers", headers_decoder())
  use body <- decode.field("body", bytes_decoder())
  case request.to(url), http.parse_method(method) {
    Ok(req), Ok(method) ->
      decode.success(
        request.Request(..req, method: method, headers: headers, body: body),
      )
    _, _ ->
      decode.failure(request.set_body(request.new(), <<>>), "HTTP request")
  }
}

fn headers_decoder() -> decode.Decoder(List(#(String, String))) {
  let pair = {
    use values <- decode.then(decode.list(decode.string))
    case values {
      [key, value] -> decode.success(#(key, value))
      _ -> decode.failure(#("", ""), "header pair")
    }
  }
  decode.list(pair)
}

fn bytes_decoder() -> decode.Decoder(BitArray) {
  use size <- decode.field("bytes", decode.int)
  use encoded <- decode.field("base64", decode.string)
  case bit_array.base64_decode(encoded) {
    Ok(bytes) ->
      case bit_array.byte_size(bytes) == size {
        True -> decode.success(bytes)
        False -> decode.failure(<<>>, "matching byte count")
      }
    Error(Nil) -> decode.failure(<<>>, "base64 bytes")
  }
}

fn reply_decoder() -> decode.Decoder(fixture.Reply) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "reject" -> {
      use failure <- decode.field("failure", failure_decoder())
      decode.success(fixture.Reject(failure))
    }
    "response" -> {
      use status <- decode.field("status", decode.int)
      use headers <- decode.field("headers", headers_decoder())
      use chunks <- decode.field("chunks", decode.list(bytes_decoder()))
      use ending <- decode.field("ending", ending_decoder())
      case status >= 200 && status <= 599 {
        True ->
          decode.success(fixture.Respond(
            response.Response(status, headers, chunks),
            ending,
          ))
        False ->
          decode.failure(
            fixture.Reject(Failure(error.FixtureCorrupt, NotSubmitted)),
            "final HTTP status",
          )
      }
    }
    _ ->
      decode.failure(
        fixture.Reject(Failure(error.FixtureCorrupt, NotSubmitted)),
        "reply kind",
      )
  }
}

fn ending_decoder() -> decode.Decoder(fixture.Ending) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "complete" -> {
      use headers <- decode.field("trailers", headers_decoder())
      decode.success(fixture.Complete(headers))
    }
    "failed" -> {
      use failure <- decode.field("failure", failure_decoder())
      decode.success(fixture.Failed(failure))
    }
    "cancelled" -> decode.success(fixture.Cancelled)
    _ -> decode.failure(fixture.Cancelled, "terminal outcome")
  }
}

fn failure_decoder() -> decode.Decoder(Failure) {
  use tag <- decode.field("reason", decode.string)
  use detail <- decode.field("detail", decode.string)
  use count <- decode.field("count", decode.int)
  use evidence <- decode.field("evidence", decode.string)
  let reason = case tag {
    "invalid_config" -> Ok(error.InvalidConfig(detail))
    "invalid_request" -> Ok(error.InvalidRequest(detail))
    "client_closed" -> Ok(error.ClientClosed)
    "admission_full" -> Ok(error.AdmissionFull)
    "connection_failed" -> Ok(error.ConnectionFailed)
    "request_failed" -> Ok(error.RequestFailed)
    "deadline" -> Ok(error.DeadlineExceeded)
    "read_timeout" -> Ok(error.ReadTimeout)
    "read_conflict" -> Ok(error.ReadConflict)
    "wrong_owner" -> Ok(error.WrongOwner)
    "closed" -> Ok(error.Closed)
    "limit" -> Ok(error.LimitExceeded(detail, count))
    "fixture_missing" -> Ok(error.FixtureMissing)
    "fixture_corrupt" -> Ok(error.FixtureCorrupt)
    "fixture_version" -> Ok(error.FixtureVersion(count))
    "fixture_exhausted" -> Ok(error.FixtureExhausted)
    "fixture_mismatch" -> Ok(error.FixtureMismatch(count))
    "capture_failed" -> Ok(error.CaptureFailed(detail))
    _ -> Error(Nil)
  }
  let evidence = case evidence {
    "not_submitted" -> Ok(error.NotSubmitted)
    "may_have_been_sent" -> Ok(error.MayHaveBeenSent)
    _ -> Error(Nil)
  }
  case reason, evidence {
    Ok(reason), Ok(evidence) -> decode.success(Failure(reason, evidence))
    _, _ ->
      decode.failure(
        Failure(error.FixtureCorrupt, NotSubmitted),
        "known failure",
      )
  }
}
