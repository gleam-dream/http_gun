//// The one strict cassette schema, version 2. Dynamic decoding is confined
//// to this boundary.
////
//// A chunk or body is `{"text": ..}` when it is valid UTF-8 and
//// `{"base64": ..}` otherwise. Failures use `error.to_json`.

import gleam/bit_array
import gleam/dynamic/decode
import gleam/http
import gleam/http/request
import gleam/json
import gleam/result
import gleam/uri
import http_gun/error
import http_gun/internal/script
import http_gun/redaction.{type Redaction}

pub const version = 2

pub type ParseError {
  Corrupt
  UnsupportedVersion(Int)
}

/// Encode exchanges with `redaction` applied to every request and to
/// response headers and trailers.
pub fn encode(exchanges: List(script.Exchange), policy: Redaction) -> String {
  json.object([
    #("http_gun", json.int(version)),
    #(
      "exchanges",
      json.array(exchanges, fn(exchange) {
        json.object([
          #(
            "request",
            request_json(redaction.request(policy, exchange.request)),
          ),
          #("reply", reply_json(redact_reply(policy, exchange.reply))),
        ])
      }),
    ),
  ])
  |> json.to_string
}

fn redact_reply(policy: Redaction, reply: script.Reply) -> script.Reply {
  case reply {
    script.Reject(_) -> reply
    script.Respond(status, headers, chunks, ending) ->
      script.Respond(
        status,
        redaction.headers(policy, headers),
        chunks,
        case ending {
          script.Finished(trailers) ->
            script.Finished(redaction.headers(policy, trailers))
          other -> other
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
  case found == version {
    False -> Error(UnsupportedVersion(found))
    True -> {
      let decoder = {
        use values <- decode.field("exchanges", decode.list(exchange_decoder()))
        decode.success(values)
      }
      json.parse(text, decoder) |> result.replace_error(Corrupt)
    }
  }
}

/// The request as stored. The caller applies the redaction first.
pub fn request_json(req: request.Request(BitArray)) -> json.Json {
  json.object([
    #("method", json.string(http.method_to_string(req.method))),
    #("url", json.string(uri.to_string(request.to_uri(req)))),
    #("headers", headers_json(req.headers)),
    #("body", bytes_json(req.body)),
  ])
}

pub fn headers_json(headers: List(#(String, String))) -> json.Json {
  json.array(headers, fn(h) { json.array([h.0, h.1], json.string) })
}

pub fn bytes_json(bytes: BitArray) -> json.Json {
  case bit_array.to_string(bytes) {
    Ok(text) -> json.object([#("text", json.string(text))])
    Error(Nil) ->
      json.object([
        #("base64", json.string(bit_array.base64_encode(bytes, True))),
      ])
  }
}

pub fn reply_json(reply: script.Reply) -> json.Json {
  case reply {
    script.Reject(failure) ->
      json.object([
        #("kind", json.string("reject")),
        #("failure", error.to_json(failure)),
      ])
    script.Respond(status, headers, chunks, ending) ->
      json.object([
        #("kind", json.string("response")),
        #("status", json.int(status)),
        #("headers", headers_json(headers)),
        #("chunks", json.array(chunks, bytes_json)),
        #("ending", ending_json(ending)),
      ])
  }
}

pub fn ending_json(ending: script.Ending) -> json.Json {
  case ending {
    script.Finished(trailers) ->
      json.object([
        #("kind", json.string("finished")),
        #("trailers", headers_json(trailers)),
      ])
    script.Aborted(failure) ->
      json.object([
        #("kind", json.string("aborted")),
        #("failure", error.to_json(failure)),
      ])
    script.Abandoned -> json.object([#("kind", json.string("abandoned"))])
  }
}

fn exchange_decoder() -> decode.Decoder(script.Exchange) {
  use req <- decode.field("request", request_decoder())
  use reply <- decode.field("reply", reply_decoder())
  decode.success(script.Exchange(req, reply))
}

fn request_decoder() -> decode.Decoder(request.Request(BitArray)) {
  use method <- decode.field("method", decode.string)
  use url <- decode.field("url", decode.string)
  use headers <- decode.field("headers", headers_decoder())
  use body <- decode.field("body", bytes_decoder())
  case request.to(url), http.parse_method(method) {
    Ok(req), Ok(method) ->
      decode.success(request.Request(..req, method:, headers:, body:))
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
  decode.one_of(
    {
      use text <- decode.field("text", decode.string)
      decode.success(bit_array.from_string(text))
    },
    [
      {
        use encoded <- decode.field("base64", decode.string)
        case bit_array.base64_decode(encoded) {
          Ok(bytes) -> decode.success(bytes)
          Error(Nil) -> decode.failure(<<>>, "base64 bytes")
        }
      },
    ],
  )
}

fn reply_decoder() -> decode.Decoder(script.Reply) {
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
      use chunks <- decode.field("chunks", decode.list(bytes_decoder()))
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
