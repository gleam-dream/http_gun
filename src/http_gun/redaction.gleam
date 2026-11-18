//// Decides which request and response data cassettes never store.
////
//// `default()` removes the credential headers `authorization`,
//// `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`,
//// `x-goog-api-key`, `x-auth-token`, `x-access-token`,
//// `x-amz-security-token` and `x-csrf-token`. One list of credential names,
//// `key`, `api_key`, `apikey`, `access_token`, `token`, `client_secret`,
//// `code`, `refresh_token`, `id_token`, `signature`, `sig`,
//// `x-amz-security-token`, `x-goog-api-key`, `x-amz-signature`,
//// `x-amz-credential`, `password`, `secret` and `authorization`, selects
//// what else is replaced by `REDACTED`:
////
//// - the value of a query parameter with a listed name;
//// - in an `application/x-www-form-urlencoded` request or response body, the
////   value of a pair with a listed name, with pairs split at `&` and `;`;
//// - in an `application/json` or `+json` body, the value of an object key
////   with a listed name at any depth, which becomes `"REDACTED"`. Every other
////   byte of the body is kept.
////
//// `request_fields_only` limits the last two to request bodies, so response
//// bodies are stored as received apart from the body function.
////
//// Names are compared without case and ignoring `-` and `_`, so `api_key`
//// also selects `API-KEY`, `apiKey` and `ApiKey`. Escapes in a JSON key are
//// not decoded: the value of any key that contains a backslash escape is
//// replaced, whatever it spells, so an escaped credential name never
//// survives. A form or JSON body that cannot be
//// scanned (a form body that is not UTF-8, JSON with an unterminated string
//// or a missing value, as a truncated or aborted body has) or that is above
//// 16 MiB is replaced as a whole by `REDACTED-UNPARSABLE`. Bodies with
//// another content type are kept; use `with_body` for those. Add your own
//// secrets, then pass the redaction to `config.with_redaction`:
////
//// ```gleam
//// let redaction =
////   redaction.default()
////   |> redaction.with_headers(["x-signature"])
////   |> redaction.with_query_parameters(["session"])
////   |> redaction.with_body_fields(["card_number"])
////   |> redaction.with_body(fn(bytes) { scrub_card_numbers(bytes) })
//// config.default() |> config.with_redaction(redaction)
//// ```
////
//// A recording client stores requests and responses with the redaction
//// applied: listed headers are removed, listed query parameters keep their
//// name with the value `REDACTED`, credential body fields are replaced, and
//// the body function rewrites request bodies and whole response bodies. A
//// request-body rewrite (`with_request_body`) applies to request bodies only,
//// so it can normalise volatile request values without touching an answer. A
//// playback client applies the same redaction to the scripted request and to
//// each incoming request before comparing them, so a recorded cassette
//// matches the live code that made it. A redacted value therefore matches
//// any live value. The live request on the network is never changed.
////
//// Failures and telemetry events never contain a URL, query or body, nor a
//// request header. A `send` or `batch` failure after the response head
//// arrived keeps the response headers (`error.headers`) with the listed
//// headers removed. A waiting request's headers are held in a closure that
//// crash reports print as a function reference. A playback client keeps the
//// requests it refused, redacted, for `testing.verify`; a crash report of
//// that client can print them.

import gleam/bit_array
import gleam/http/request.{type Request}
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import gleam/uri

/// What to remove from stored exchanges. The `default()` credentials are
/// always removed; the functions below only add to the lists, except
/// `request_fields_only`, which stops replacing fields in response bodies.
pub opaque type Redaction {
  Redaction(
    headers: List(String),
    names: List(String),
    body: Option(fn(BitArray) -> BitArray),
    request_body: Option(fn(BitArray) -> BitArray),
    /// Lowercased request header names to keep, once
    /// `keeping_request_headers` is called, even with no names.
    kept_request_headers: Option(List(String)),
    /// Whether credential fields are replaced in response bodies too.
    response_fields: Bool,
  )
}

const credential_headers = [
  "authorization",
  "proxy-authorization",
  "cookie",
  "set-cookie",
  "x-api-key",
  "api-key",
  "x-goog-api-key",
  "x-auth-token",
  "x-access-token",
  "x-amz-security-token",
  "x-csrf-token",
]

const credential_parameters = [
  "key",
  "api_key",
  "apikey",
  "access_token",
  "token",
  "client_secret",
  "code",
  "refresh_token",
  "id_token",
  "signature",
  "sig",
  "x-amz-security-token",
  "x-goog-api-key",
  "x-amz-signature",
  "x-amz-credential",
]

const credential_fields = [
  "client_secret",
  "access_token",
  "refresh_token",
  "id_token",
  "api_key",
  "password",
  "secret",
  "token",
  "authorization",
]

/// Bodies above this size are not scanned for credential fields. No
/// recording or script can hold one.
const max_scanned_bytes = 16_777_216

const marker = "REDACTED"

/// Replaces a whole form or JSON body that cannot be scanned.
const unparsable = "REDACTED-UNPARSABLE"

/// Remove the credential headers, and replace credential query parameters
/// and credential fields in form and JSON bodies, as the module
/// documentation lists.
pub fn default() -> Redaction {
  Redaction(
    headers: credential_headers,
    names: add_names([], list.append(credential_parameters, credential_fields)),
    body: None,
    request_body: None,
    kept_request_headers: None,
    response_fields: True,
  )
}

/// Names compare without case and without `-` or `_`, so `api-key`,
/// `api_key`, `apiKey` and `APIKEY` are one name.
fn normalise(name: String) -> String {
  name
  |> string.lowercase
  |> string.replace("-", "")
  |> string.replace("_", "")
}

fn add_names(names: List(String), added: List(String)) -> List(String) {
  list.unique(list.append(names, list.map(added, normalise)))
}

/// Also remove these headers, compared without case, from stored requests
/// and responses, including trailers, and from the response headers a
/// failure keeps.
pub fn with_headers(redaction: Redaction, names: List(String)) -> Redaction {
  let names = list.map(names, string.lowercase)
  Redaction(
    ..redaction,
    headers: list.unique(list.append(redaction.headers, names)),
  )
}

/// Replace the value of these query parameters with `REDACTED`, compared by
/// percent-decoded name without case and ignoring `-` and `_`. The parameter
/// order and every other byte of the query stay as sent. Query parameters
/// and body fields share one list, so the names also apply to form and JSON
/// bodies.
pub fn with_query_parameters(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(..redaction, names: add_names(redaction.names, names))
}

/// Also replace the value of these fields in form and JSON bodies, compared
/// as `with_query_parameters` compares names. Query parameters and body
/// fields share one list, so the names also apply to the query.
pub fn with_body_fields(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  Redaction(..redaction, names: add_names(redaction.names, names))
}

/// Rewrite stored bodies with `redact`, after the credential fields are
/// replaced: each request body, and each response
/// body as a whole. A recording buffers a response body until it ends, within
/// the recording's byte budget, and stores the rewritten body as one chunk,
/// so a secret split across chunks is still seen whole. Playback applies
/// `redact` to the scripted and the incoming request bodies before
/// comparing. Calling it again replaces the function.
pub fn with_body(
  redaction: Redaction,
  redact: fn(BitArray) -> BitArray,
) -> Redaction {
  Redaction(..redaction, body: Some(redact))
}

/// Rewrite request bodies only, after the credential fields are replaced and
/// after `with_body`: the body a recording stores, and both the scripted and
/// the incoming body that playback compares. Response bodies are never
/// passed to `rewrite`, so normalising volatile request values (a time, an
/// id, inline image data) cannot edit a recorded answer. Playback redacts a
/// stored body again, so redacting the rewrite's output once more must change
/// nothing: `rewrite`, the credential fields and `with_body` must each leave
/// it as it is. Calling it again replaces the function.
pub fn with_request_body(
  redaction: Redaction,
  rewrite: fn(BitArray) -> BitArray,
) -> Redaction {
  Redaction(..redaction, request_body: Some(rewrite))
}

/// Store and compare only these request headers, compared without case, and
/// `content-type`, which field redaction reads. A request header nobody named
/// is then left out of recordings and out of matching on both sides, so a
/// new header a client starts sending is never stored. The removed headers
/// still apply: a named credential header is removed. Repeated calls add
/// names. Response headers, trailers and the headers a failure keeps are not
/// affected.
pub fn keeping_request_headers(
  redaction: Redaction,
  names: List(String),
) -> Redaction {
  let names = list.map(names, string.lowercase)
  let kept = case redaction.kept_request_headers {
    Some(kept) -> list.unique(list.append(kept, names))
    None -> list.unique(["content-type", ..names])
  }
  Redaction(..redaction, kept_request_headers: Some(kept))
}

/// Replace credential fields in request bodies and the query only, and
/// store response bodies as received apart from `with_body`: with no body
/// function, a response body keeps its received chunks. Use it when a
/// recorded answer must replay exactly, for example a JSON error body with a
/// `code` field; you then own keeping secrets, such as an OAuth token answer,
/// out of your cassettes. It is the one call that stores more, it cannot be
/// undone, and calling it again changes nothing.
pub fn request_fields_only(redaction: Redaction) -> Redaction {
  Redaction(..redaction, response_fields: False)
}

/// Rewrite a response body as a recording stores it: credential fields, if
/// this redaction replaces them in responses, then the body function.
@internal
pub fn response_body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
  bytes: BitArray,
) -> BitArray {
  case redaction.response_fields {
    True -> body_for(redaction, headers, bytes)
    False -> body(redaction, bytes)
  }
}

/// Whether `response_body_for` can change a response body with these
/// headers, so a recording holds it whole.
@internal
pub fn rewrites_response_body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> Bool {
  case redaction.response_fields {
    True -> rewrites_body_for(redaction, headers)
    False -> rewrites_bodies(redaction)
  }
}

/// Remove the redacted headers from a header list. The request header
/// allow-list is not applied; `request` applies it.
pub fn headers(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  list.filter(headers, fn(header) {
    !list.contains(redaction.headers, string.lowercase(header.0))
  })
}

/// Apply the redaction to a request: keep only the allowed request headers,
/// if any are named, remove headers, replace query values,
/// rewrite the body for its `content-type`, as `body_for` does, then apply the
/// request-body rewrite, if any.
pub fn request(
  redaction: Redaction,
  req: Request(BitArray),
) -> Request(BitArray) {
  request.Request(
    ..req,
    headers: headers(redaction, request_headers(redaction, req.headers)),
    query: option.map(req.query, query(redaction, _)),
    body: case redaction.request_body {
      Some(rewrite) -> rewrite(body_for(redaction, req.headers, req.body))
      None -> body_for(redaction, req.headers, req.body)
    },
  )
}

/// Rewrite a request or response body with the `content-type` in `headers`,
/// by the default rule for both directions (a recording applies
/// `request_fields_only` to responses on top of this):
/// replace the credential fields of a form or JSON body, then apply the body
/// function, if any. The request-body rewrite is not applied; `request`
/// applies it.
pub fn body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
  bytes: BitArray,
) -> BitArray {
  body(redaction, fields(redaction, content_kind(headers), bytes))
}

/// Whether `body_for` can change a body with these headers: a body function
/// is set, or the content type is form or JSON.
pub fn rewrites_body_for(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> Bool {
  rewrites_bodies(redaction) || content_kind(headers) != Opaque
}

/// Apply the body function, if any. Credential fields are not replaced; use
/// `body_for`.
pub fn body(redaction: Redaction, bytes: BitArray) -> BitArray {
  case redaction.body {
    Some(redact) -> redact(bytes)
    None -> bytes
  }
}

/// Whether this redaction has a body function. Credential fields are replaced
/// whatever this returns (in responses too, unless `request_fields_only`);
/// see `rewrites_body_for`.
pub fn rewrites_bodies(redaction: Redaction) -> Bool {
  option.is_some(redaction.body)
}

fn request_headers(
  redaction: Redaction,
  headers: List(#(String, String)),
) -> List(#(String, String)) {
  case redaction.kept_request_headers {
    None -> headers
    Some(kept) ->
      list.filter(headers, fn(header) {
        list.contains(kept, string.lowercase(header.0))
      })
  }
}

fn query(redaction: Redaction, query: String) -> String {
  pairs(query, redaction.names, ["&"])
}

/// Replace the value of each pair, split at `separators`, whose
/// percent-decoded, normalised name is in `names`, keeping every other byte.
fn pairs(
  text: String,
  names: List(String),
  separators: List(String),
) -> String {
  case separators {
    [separator, ..rest] ->
      string.split(text, separator)
      |> list.map(pairs(_, names, rest))
      |> string.join(separator)
    [] -> {
      let name = case string.split_once(text, "=") {
        Ok(#(name, _)) -> name
        Error(Nil) -> text
      }
      let decoded = case uri.percent_decode(string.replace(name, "+", " ")) {
        Ok(decoded) -> decoded
        Error(Nil) -> name
      }
      case list.contains(names, normalise(decoded)) {
        True -> name <> "=" <> marker
        False -> text
      }
    }
  }
}

type ContentKind {
  Form
  Json
  Opaque
}

fn content_kind(headers: List(#(String, String))) -> ContentKind {
  let found =
    list.find(headers, fn(header) {
      string.lowercase(header.0) == "content-type"
    })
  case found {
    Error(Nil) -> Opaque
    Ok(#(_, value)) -> {
      let media = case string.split_once(value, ";") {
        Ok(#(media, _)) -> media
        Error(Nil) -> value
      }
      case string.lowercase(string.trim(media)) {
        "application/x-www-form-urlencoded" -> Form
        "application/json" -> Json
        media ->
          case string.ends_with(media, "+json") {
            True -> Json
            False -> Opaque
          }
      }
    }
  }
}

// A form or JSON body that cannot be scanned fails closed: it may be a
// truncated body whose secret value is cut short, so it is replaced whole.
fn fields(
  redaction: Redaction,
  kind: ContentKind,
  bytes: BitArray,
) -> BitArray {
  case kind, bit_array.byte_size(bytes) > max_scanned_bytes {
    Opaque, _ -> bytes
    _, True -> bit_array.from_string(unparsable)
    Form, False ->
      case bit_array.to_string(bytes) {
        Ok(text) ->
          bit_array.from_string(pairs(text, redaction.names, ["&", ";"]))
        Error(Nil) -> bit_array.from_string(unparsable)
      }
    Json, False ->
      case json_from(bytes, redaction.names, []) {
        Ok(parts) -> bit_array.concat(list.reverse(parts))
        Error(Nil) -> bit_array.from_string(unparsable)
      }
  }
}

// A byte scanner, not a JSON parser: it finds each string followed by `:`
// (an object key) and replaces the value after a named key, keeping every
// other byte, so redacting twice changes nothing more. `parts` is reversed.
fn json_from(
  rest: BitArray,
  names: List(String),
  parts: List(BitArray),
) -> Result(List(BitArray), Nil) {
  let #(plain, rest) = until_quote(rest, rest, 0)
  let parts = [plain, ..parts]
  case rest {
    <<"\"":utf8, after:bytes>> -> {
      use #(raw, after) <- result.try(string_end(after, after, 0))
      let parts = [<<"\"":utf8, raw:bits, "\"":utf8>>, ..parts]
      let #(space, following) = spaces(after, after, 0)
      case following, named(raw, names) {
        <<":":utf8, value:bytes>>, True -> {
          let #(gap, value) = spaces(value, value, 0)
          use rest <- result.try(skip_value(value))
          json_from(rest, names, [
            <<"\"":utf8, marker:utf8, "\"":utf8>>,
            gap,
            <<":":utf8>>,
            space,
            ..parts
          ])
        }
        _, _ -> json_from(after, names, parts)
      }
    }
    _ -> Ok(parts)
  }
}

// Escapes are not decoded: a key with a backslash escape, or one that is not
// UTF-8, could spell a listed name, so its value is redacted.
fn named(raw: BitArray, names: List(String)) -> Bool {
  case bit_array.to_string(raw) {
    Ok(name) ->
      string.contains(name, "\\") || list.contains(names, normalise(name))
    Error(Nil) -> True
  }
}

fn take(bytes: BitArray, count: Int) -> BitArray {
  case bytes {
    <<head:bytes-size(count), _:bytes>> -> head
    _ -> bytes
  }
}

fn until_quote(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<"\"":utf8, _:bytes>> | <<>> -> #(take(start, count), rest)
    <<_, more:bytes>> -> until_quote(start, more, count + 1)
    _ -> #(start, <<>>)
  }
}

// The bytes of a string after its opening quote, and the rest after its
// closing quote.
fn string_end(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> Result(#(BitArray, BitArray), Nil) {
  case rest {
    <<"\\":utf8, _, more:bytes>> -> string_end(start, more, count + 2)
    <<"\"":utf8, more:bytes>> -> Ok(#(take(start, count), more))
    <<_, more:bytes>> -> string_end(start, more, count + 1)
    _ -> Error(Nil)
  }
}

fn spaces(
  start: BitArray,
  rest: BitArray,
  count: Int,
) -> #(BitArray, BitArray) {
  case rest {
    <<byte, more:bytes>>
      if byte == 32 || byte == 9 || byte == 10 || byte == 13
    -> spaces(start, more, count + 1)
    _ -> #(take(start, count), rest)
  }
}

// The rest after one value: a string, a bracketed value or a scalar.
fn skip_value(value: BitArray) -> Result(BitArray, Nil) {
  case value {
    <<"\"":utf8, more:bytes>> ->
      string_end(more, more, 0) |> result.map(fn(found) { found.1 })
    <<"{":utf8, more:bytes>> | <<"[":utf8, more:bytes>> -> nested(more, 1)
    _ -> scalar(value, 0)
  }
}

fn nested(rest: BitArray, depth: Int) -> Result(BitArray, Nil) {
  case rest {
    <<"\"":utf8, more:bytes>> -> {
      use #(_, after) <- result.try(string_end(more, more, 0))
      nested(after, depth)
    }
    <<"{":utf8, more:bytes>> | <<"[":utf8, more:bytes>> ->
      nested(more, depth + 1)
    <<"}":utf8, more:bytes>> | <<"]":utf8, more:bytes>> ->
      case depth {
        1 -> Ok(more)
        _ -> nested(more, depth - 1)
      }
    <<_, more:bytes>> -> nested(more, depth)
    _ -> Error(Nil)
  }
}

fn scalar(rest: BitArray, count: Int) -> Result(BitArray, Nil) {
  case rest, count {
    <<byte, _:bytes>>, _
      if byte == 44
      || byte == 125
      || byte == 93
      || byte == 32
      || byte == 9
      || byte == 10
      || byte == 13
    -> stop(rest, count)
    <<_, more:bytes>>, _ -> scalar(more, count + 1)
    _, _ -> stop(rest, count)
  }
}

fn stop(rest: BitArray, count: Int) -> Result(BitArray, Nil) {
  case count {
    0 -> Error(Nil)
    _ -> Ok(rest)
  }
}
