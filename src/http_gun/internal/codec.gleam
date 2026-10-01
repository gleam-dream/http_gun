//// One strict cassette schema. Dynamic decoding is confined to this boundary.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/option.{Some}
import gleam/result
import gleam/string
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
    error.DestinationRejected -> #("destination_rejected", "", 0)
    error.ResolutionFailed -> #("resolution_failed", "", 0)
    error.ConnectionFailed(cause) -> #("connection_failed", cause_tag(cause), 0)
    error.RequestFailed(cause) -> #("request_failed", cause_tag(cause), 0)
    error.DeadlineExceeded -> #("deadline", "", 0)
    error.ReadTimeout -> #("read_timeout", "", 0)
    error.ReadConflict -> #("read_conflict", "", 0)
    error.WrongOwner -> #("wrong_owner", "", 0)
    error.Cancelled -> #("cancelled", "", 0)
    error.Closed -> #("closed", "", 0)
    error.LimitExceeded(kind, limit, _) -> #("limit", limit_tag(kind), limit)
    error.FixtureIo(operation, cause) -> #(
      "fixture_io",
      file_operation_tag(operation) <> ":" <> file_cause_tag(cause),
      0,
    )
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
  let observed = case failure.reason {
    error.LimitExceeded(_, _, count) -> json.int(count)
    _ -> json.null()
  }
  json.object([
    #("observed", observed),
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
  use observed <- decode.field("observed", decode.optional(decode.int))
  let reason = case tag {
    "invalid_config" -> Ok(error.InvalidConfig(detail))
    "invalid_request" -> Ok(error.InvalidRequest(detail))
    "client_closed" -> Ok(error.ClientClosed)
    "admission_full" -> Ok(error.AdmissionFull)
    "destination_rejected" -> Ok(error.DestinationRejected)
    "resolution_failed" -> Ok(error.ResolutionFailed)
    "connection_failed" ->
      result.map(parse_cause(detail), error.ConnectionFailed)
    "request_failed" -> result.map(parse_cause(detail), error.RequestFailed)
    "deadline" -> Ok(error.DeadlineExceeded)
    "read_timeout" -> Ok(error.ReadTimeout)
    "read_conflict" -> Ok(error.ReadConflict)
    "wrong_owner" -> Ok(error.WrongOwner)
    "cancelled" -> Ok(error.Cancelled)
    "closed" -> Ok(error.Closed)
    "limit" -> {
      let kind = parse_limit(detail)
      case observed {
        Some(n) if n >= 0 ->
          result.map(kind, fn(k) { error.LimitExceeded(k, count, n) })
        _ -> Error(Nil)
      }
    }
    "fixture_io" -> parse_file_error(detail)
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

fn limit_tag(kind: error.LimitKind) -> String {
  case kind {
    error.RequestBodyBytes -> "request_body_bytes"
    error.RequestHeaderBytes -> "request_header_bytes"
    error.RequestHeaderCount -> "request_header_count"
    error.ResponseHeaderBytes -> "response_header_bytes"
    error.ResponseHeaderCount -> "response_header_count"
    error.ResponseChunkBytes -> "response_chunk_bytes"
    error.ResponseQueueBytes -> "response_queue_bytes"
    error.CollectedBodyBytes -> "collected_body_bytes"
    error.FixtureBytes -> "fixture_bytes"
  }
}

fn parse_limit(tag: String) -> Result(error.LimitKind, Nil) {
  case tag {
    "request_body_bytes" -> Ok(error.RequestBodyBytes)
    "request_header_bytes" -> Ok(error.RequestHeaderBytes)
    "request_header_count" -> Ok(error.RequestHeaderCount)
    "response_header_bytes" -> Ok(error.ResponseHeaderBytes)
    "response_header_count" -> Ok(error.ResponseHeaderCount)
    "response_chunk_bytes" -> Ok(error.ResponseChunkBytes)
    "response_queue_bytes" -> Ok(error.ResponseQueueBytes)
    "collected_body_bytes" -> Ok(error.CollectedBodyBytes)
    "fixture_bytes" -> Ok(error.FixtureBytes)
    _ -> Error(Nil)
  }
}

fn cause_tag(cause: error.TransportCause) -> String {
  case cause {
    error.NameResolutionFailed -> "name_resolution_failed"
    error.ConnectionRefused -> "connection_refused"
    error.CertificateRejected -> "certificate_rejected"
    error.TlsFailed -> "tls_failed"
    error.ConnectionReset -> "connection_reset"
    error.PeerClosed -> "peer_closed"
    error.PeerDraining -> "peer_draining"
    error.ProtocolError -> "protocol_error"
    error.HeaderLimitReached -> "header_limit_reached"
    error.TransportTimeout -> "transport_timeout"
    error.UnexpectedProtocol -> "unexpected_protocol"
    error.UnknownTransport -> "unknown_transport"
  }
}

fn parse_cause(tag: String) -> Result(error.TransportCause, Nil) {
  case tag {
    "name_resolution_failed" -> Ok(error.NameResolutionFailed)
    "connection_refused" -> Ok(error.ConnectionRefused)
    "certificate_rejected" -> Ok(error.CertificateRejected)
    "tls_failed" -> Ok(error.TlsFailed)
    "connection_reset" -> Ok(error.ConnectionReset)
    "peer_closed" -> Ok(error.PeerClosed)
    "peer_draining" -> Ok(error.PeerDraining)
    "protocol_error" -> Ok(error.ProtocolError)
    "header_limit_reached" -> Ok(error.HeaderLimitReached)
    "transport_timeout" -> Ok(error.TransportTimeout)
    "unexpected_protocol" -> Ok(error.UnexpectedProtocol)
    "unknown_transport" -> Ok(error.UnknownTransport)
    _ -> Error(Nil)
  }
}

fn file_operation_tag(operation: error.FileOperation) -> String {
  case operation {
    error.OpenFile -> "open_file"
    error.ReadFile -> "read_file"
    error.WriteFile -> "write_file"
    error.CloseFile -> "close_file"
    error.CreateDirectory -> "create_directory"
    error.SetPermissions -> "set_permissions"
    error.PublishFixture -> "publish_fixture"
  }
}

fn file_cause_tag(cause: error.FileCause) -> String {
  case cause {
    error.FileMissing -> "file_missing"
    error.AlreadyExists -> "already_exists"
    error.PermissionDenied -> "permission_denied"
    error.NoSpace -> "no_space"
    error.ReadOnlyFilesystem -> "read_only_filesystem"
    error.NotDirectory -> "not_directory"
    error.IsDirectory -> "is_directory"
    error.CrossFilesystem -> "cross_filesystem"
    error.UnknownIoFailure -> "unknown_io_failure"
  }
}

fn parse_file_error(detail: String) -> Result(error.Reason, Nil) {
  use #(operation, cause) <- result.try(case string.split(detail, ":") {
    [o, c] -> Ok(#(o, c))
    _ -> Error(Nil)
  })
  use operation <- result.try(case operation {
    "open_file" -> Ok(error.OpenFile)
    "read_file" -> Ok(error.ReadFile)
    "write_file" -> Ok(error.WriteFile)
    "close_file" -> Ok(error.CloseFile)
    "create_directory" -> Ok(error.CreateDirectory)
    "set_permissions" -> Ok(error.SetPermissions)
    "publish_fixture" -> Ok(error.PublishFixture)
    _ -> Error(Nil)
  })
  use cause <- result.try(case cause {
    "file_missing" -> Ok(error.FileMissing)
    "already_exists" -> Ok(error.AlreadyExists)
    "permission_denied" -> Ok(error.PermissionDenied)
    "no_space" -> Ok(error.NoSpace)
    "read_only_filesystem" -> Ok(error.ReadOnlyFilesystem)
    "not_directory" -> Ok(error.NotDirectory)
    "is_directory" -> Ok(error.IsDirectory)
    "cross_filesystem" -> Ok(error.CrossFilesystem)
    "unknown_io_failure" -> Ok(error.UnknownIoFailure)
    _ -> Error(Nil)
  })
  Ok(error.FixtureIo(operation, cause))
}
