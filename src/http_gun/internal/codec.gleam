//// The cassette schema: version 3 is written, versions 2 and 3 are read.
//// Dynamic decoding is confined to this boundary.
////
//// A chunk or body is `{"lines": [..]}` when it is valid UTF-8 containing a
//// newline (version 3 only), `{"text": ..}` when it is other valid UTF-8 and
//// `{"base64": ..}` otherwise. Failures use `error.to_json`, on one line.
////
//// The layout is owned here as fragments: `encode` concatenates them, and
//// the recorder writes the same fragments as it captures, so a recorded file
//// and its upgraded form are the same text. Separators lead the element they
//// precede and a closing bracket depends only on whether its array held an
//// element, so a streamed writer needs no lookahead.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun/error
import http_gun/internal/script
import http_gun/redaction.{type Redaction}

pub const version = 3

pub type ParseError {
  Corrupt
  UnsupportedVersion(Int)
}

/// Encode exchanges with `redaction` applied to every request and to
/// response headers, bodies and trailers. A rewritten response body is
/// stored as one chunk, as a recording stores it.
pub fn encode(exchanges: List(script.Exchange), policy: Redaction) -> String {
  render(list.map(exchanges, store(policy, _)))
}

/// Lay out exchanges already in their stored form, without redacting them.
pub fn render(exchanges: List(script.Exchange)) -> String {
  let #(text, any) =
    list.fold(exchanges, #(envelope_open, False), fn(acc, exchange) {
      let #(text, any) = acc
      #(text <> exchange_text(!any, exchange), True)
    })
  text <> envelope_close(any)
}

fn exchange_text(first: Bool, exchange: script.Exchange) -> String {
  exchange_open(first, exchange.request)
  <> case exchange.reply {
    script.Reject(failure) -> reject(failure)
    script.Respond(status, headers, chunks, ending) -> {
      let #(body, any) =
        list.fold(chunks, #("", False), fn(acc, bytes) {
          #(acc.0 <> chunk(!acc.1, bytes), True)
        })
      response_head(status, headers) <> body <> response_end(any, ending)
    }
  }
}

/// Opens the file; the exchanges follow.
pub const envelope_open = "{\n  \"http_gun\": 3,\n  \"exchanges\": ["

/// Closes the file after its exchanges, if `any`.
pub fn envelope_close(any: Bool) -> String {
  case any {
    True -> "\n  ]\n}\n"
    False -> "]\n}\n"
  }
}

/// An exchange's separator, its stored request and the opening of its reply.
pub fn exchange_open(first: Bool, req: request.Request(BitArray)) -> String {
  separator(first)
  <> "    {\n      \"request\": {\n        \"method\": "
  <> quoted(http.method_to_string(req.method))
  <> ",\n        \"scheme\": "
  <> quoted(http.scheme_to_string(req.scheme))
  <> ",\n        \"host\": "
  <> quoted(req.host)
  <> ",\n        \"port\": "
  <> case req.port {
    Some(port) -> int.to_string(port)
    None -> "null"
  }
  <> ",\n        \"path\": "
  <> quoted(req.path)
  <> ",\n        \"query\": "
  <> case req.query {
    Some(query) -> quoted(query)
    None -> "null"
  }
  <> ",\n        \"headers\": "
  <> pairs(req.headers, 10)
  <> ",\n        \"body\": "
  <> bytes_text(req.body, 8)
  <> "\n      },\n      \"reply\": "
}

/// A rejected reply, closing its exchange.
pub fn reject(failure: error.Failure) -> String {
  "{\"kind\": \"reject\", \"failure\": "
  <> json.to_string(error.to_json(failure))
  <> "}"
  <> exchange_close
}

/// A response's status and headers, opening its chunks.
pub fn response_head(status: Int, headers: List(#(String, String))) -> String {
  "{\n        \"kind\": \"response\",\n        \"status\": "
  <> int.to_string(status)
  <> ",\n        \"headers\": "
  <> pairs(headers, 10)
  <> ",\n        \"chunks\": ["
}

/// One chunk, led by its separator.
pub fn chunk(first: Bool, bytes: BitArray) -> String {
  case first {
    True -> "\n"
    False -> ",\n"
  }
  <> indent(10)
  <> bytes_text(bytes, 10)
}

/// Closes the chunks, if `any`, writes the ending and closes the exchange.
pub fn response_end(any: Bool, ending: script.Ending) -> String {
  case any {
    True -> "\n" <> indent(8) <> "]"
    False -> "]"
  }
  <> ",\n        \"ending\": "
  <> case ending {
    script.Finished(trailers) ->
      "{\"kind\": \"finished\", \"trailers\": " <> pairs(trailers, 10) <> "}"
    script.Aborted(failure) ->
      "{\"kind\": \"aborted\", \"failure\": "
      <> json.to_string(error.to_json(failure))
      <> "}"
    script.Abandoned -> "{\"kind\": \"abandoned\"}"
  }
  <> "\n      }"
  <> exchange_close
}

const exchange_close = "\n    }"

fn separator(first: Bool) -> String {
  case first {
    True -> "\n"
    False -> ",\n"
  }
}

fn indent(width: Int) -> String {
  string.repeat(" ", width)
}

fn quoted(text: String) -> String {
  json.to_string(json.string(text))
}

// Header pairs, one per line at `depth`, the closing bracket two less.
fn pairs(headers: List(#(String, String)), depth: Int) -> String {
  case headers {
    [] -> "[]"
    _ ->
      "["
      <> {
        list.map(headers, fn(pair) {
          "\n"
          <> indent(depth)
          <> "["
          <> quoted(pair.0)
          <> ", "
          <> quoted(pair.1)
          <> "]"
        })
        |> string.join(",")
      }
      <> "\n"
      <> indent(depth - 2)
      <> "]"
  }
}

// A body or chunk whose own line is indented `depth`: its lines, if any, go
// two deeper and the closing bracket back at `depth`.
fn bytes_text(bytes: BitArray, depth: Int) -> String {
  case bit_array.to_string(bytes) {
    Ok(text) ->
      case string.contains(text, "\n") {
        True ->
          "{\"lines\": ["
          <> {
            string.split(text, "\n")
            |> list.map(fn(line) { "\n" <> indent(depth + 2) <> quoted(line) })
            |> string.join(",")
          }
          <> "\n"
          <> indent(depth)
          <> "]}"
        False -> "{\"text\": " <> quoted(text) <> "}"
      }
    Error(Nil) ->
      "{\"base64\": " <> quoted(bit_array.base64_encode(bytes, True)) <> "}"
  }
}

/// The form a recording under `policy` stores an exchange in: the request
/// redacted, response headers, trailers and the headers a stored failure
/// holds filtered, and a rewritten
/// response body held as one chunk. Encoding uses it; the recorder's streamed
/// fragments are tested against it.
pub fn store(policy: Redaction, exchange: script.Exchange) -> script.Exchange {
  script.Exchange(
    redaction.request(policy, exchange.request),
    redact_reply(policy, exchange.reply),
  )
}

fn redact_failure(policy: Redaction, failure: error.Failure) -> error.Failure {
  error.with_headers(failure, redaction.headers(policy, error.headers(failure)))
}

fn redact_reply(policy: Redaction, reply: script.Reply) -> script.Reply {
  case reply {
    script.Reject(failure) -> script.Reject(redact_failure(policy, failure))
    script.Respond(status, headers, chunks, ending) ->
      script.Respond(
        status,
        redaction.headers(policy, headers),
        case redaction.rewrites_body_for(policy, headers) {
          False -> chunks
          True ->
            case redaction.body_for(policy, headers, bit_array.concat(chunks)) {
              <<>> -> []
              body -> [body]
            }
        },
        case ending {
          script.Finished(trailers) ->
            script.Finished(redaction.headers(policy, trailers))
          script.Aborted(failure) ->
            script.Aborted(redact_failure(policy, failure))
          script.Abandoned -> script.Abandoned
        },
      )
  }
}

pub fn parse(text: String) -> Result(List(script.Exchange), ParseError) {
  let version_decoder = {
    use value <- decode.field("http_gun", decode.int)
    decode.success(value)
  }
  use found <- result.try(
    json.parse(text, version_decoder) |> result.replace_error(Corrupt),
  )
  case found {
    2 | 3 -> {
      let decoder = {
        use values <- decode.field(
          "exchanges",
          decode.list(exchange_decoder(found)),
        )
        decode.success(values)
      }
      json.parse(text, decoder) |> result.replace_error(Corrupt)
    }
    _ -> Error(UnsupportedVersion(found))
  }
}

fn exchange_decoder(version: Int) -> decode.Decoder(script.Exchange) {
  use req <- decode.field("request", request_decoder(version))
  use reply <- decode.field("reply", reply_decoder(version))
  decode.success(script.Exchange(req, reply))
}

fn request_decoder(version: Int) -> decode.Decoder(request.Request(BitArray)) {
  let failed = request.set_body(request.new(), <<>>)
  use method <- decode.field("method", decode.string)
  use headers <- decode.field("headers", headers_decoder())
  use body <- decode.field("body", bytes_decoder(version))
  use target <- decode.then(case version {
    // Version 3 stores the target in fields, read back as stored.
    3 -> {
      use scheme <- decode.field("scheme", decode.string)
      use host <- decode.field("host", decode.string)
      use port <- decode.field("port", decode.optional(decode.int))
      use path <- decode.field("path", decode.string)
      use query <- decode.field("query", decode.optional(decode.string))
      case http.scheme_from_string(scheme) {
        Ok(scheme) ->
          decode.success(
            request.Request(..failed, scheme:, host:, port:, path:, query:),
          )
        Error(Nil) -> decode.failure(failed, "HTTP scheme")
      }
    }
    // Version 2 stores one URL.
    _ -> {
      use url <- decode.field("url", decode.string)
      case request.to(url) {
        Ok(req) -> decode.success(request.set_body(req, <<>>))
        Error(Nil) -> decode.failure(failed, "HTTP URL")
      }
    }
  })
  case http.parse_method(method) {
    Ok(method) ->
      decode.success(request.Request(..target, method:, headers:, body:))
    Error(Nil) -> decode.failure(failed, "HTTP method")
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

// The first of text, base64 and (version 3) lines that decodes.
fn bytes_decoder(version: Int) -> decode.Decoder(BitArray) {
  let base64 = {
    use encoded <- decode.field("base64", decode.string)
    case bit_array.base64_decode(encoded) {
      Ok(bytes) -> decode.success(bytes)
      Error(Nil) -> decode.failure(<<>>, "base64 bytes")
    }
  }
  let lines = {
    use lines <- decode.field("lines", decode.list(decode.string))
    case lines {
      [_, _, ..] ->
        decode.success(bit_array.from_string(string.join(lines, "\n")))
      _ -> decode.failure(<<>>, "at least two lines")
    }
  }
  decode.one_of(
    {
      use text <- decode.field("text", decode.string)
      decode.success(bit_array.from_string(text))
    },
    case version {
      3 -> [base64, lines]
      _ -> [base64]
    },
  )
}

fn reply_decoder(version: Int) -> decode.Decoder(script.Reply) {
  let corrupt = script.Reject(error.new(error.ClientClosed, error.NotSent))
  use kind <- decode.field("kind", decode.string)
  case kind {
    "reject" -> {
      use failure <- decode.field("failure", error.decoder())
      decode.success(script.Reject(failure))
    }
    "response" -> {
      use status <- decode.field("status", decode.int)
      use headers <- decode.field("headers", headers_decoder())
      use chunks <- decode.field("chunks", decode.list(bytes_decoder(version)))
      use ending <- decode.field("ending", ending_decoder())
      case status >= 200 && status <= 599 {
        True -> decode.success(script.Respond(status, headers, chunks, ending))
        False -> decode.failure(corrupt, "final HTTP status")
      }
    }
    _ -> decode.failure(corrupt, "reply kind")
  }
}

fn ending_decoder() -> decode.Decoder(script.Ending) {
  use kind <- decode.field("kind", decode.string)
  case kind {
    "finished" -> {
      use trailers <- decode.field("trailers", headers_decoder())
      decode.success(script.Finished(trailers))
    }
    "aborted" -> {
      use failure <- decode.field("failure", error.decoder())
      decode.success(script.Aborted(failure))
    }
    "abandoned" -> decode.success(script.Abandoned)
    _ -> decode.failure(script.Abandoned, "terminal outcome")
  }
}
