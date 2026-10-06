import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/json
import gleam/list
import gleam/option.{None, Some}
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/testing

pub fn typed_collection_limit_reports_observed_bytes_test() {
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    testing.exchange(
      req,
      testing.Respond(
        response.new(200) |> response.set_body([<<0, 255, 128>>]),
        testing.Finished([]),
      ),
    )
  let assert Ok(client) =
    testing.playback(testing.script([exchange]), config.default())
  let assert Ok(reply) = http_gun.open(client, req)
  let assert Error(failure) = body.collect(reply.body, 2)
  failure
  |> should.equal(
    error.new(
      error.LimitExceeded(error.ResponseBodyBytes, 2, 3),
      error.MaybeSent,
    )
    |> error.with_status(200),
  )
  error.status(failure) |> should.equal(Some(200))
  http_gun.stop(client)
}

pub fn descriptions_omit_free_form_details_test() {
  error.describe(error.new(
    error.InvalidRequest(error.InvalidTarget),
    error.NotSent,
  ))
  |> should.equal("Invalid HTTP request: invalid path or query; not sent")
  error.describe(error.new(error.RecordingClosed, error.MaybeSent))
  |> should.equal("Recording closed; request may have been sent")
  error.describe(
    error.new(
      error.LimitExceeded(error.ResponseBodyBytes, 2, 3),
      error.MaybeSent,
    )
    |> error.with_status(200),
  )
  |> should.equal(
    "Response body bytes limit 2; observed 3; status 200; request may have been sent",
  )
  error.describe(error.new(
    error.DestinationRejected(destination.AddressRefused(destination.Private)),
    error.NotSent,
  ))
  |> should.equal(
    "Network destination rejected: private address refused; not sent",
  )
}

// Failures produced from requests full of secrets never repeat them.
pub fn descriptions_never_contain_request_values_test() {
  let secret = fn(req: request.Request(BitArray)) {
    req
    |> request.set_host("secret-host.test")
    |> request.set_query([#("token", "secret-query")])
    |> request.set_header("authorization", "Bearer secret-header")
    |> request.set_header("x-api-key", "secret-key")
  }
  let base =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_path("/secret-path")
    |> request.set_body(<<"secret-body":utf8>>)
    |> secret
  let assert Ok(live) =
    http_gun.start(
      config.default()
      |> config.with_resolver(fn(_, _) { Error(Nil) }),
    )
  let assert Ok(public_only) = http_gun.start(config.default())
  let assert Ok(scripted) =
    testing.playback(
      testing.script([
        testing.exchange(
          request.new() |> request.set_body(<<>>),
          testing.Reject(error.new(error.ClientClosed, error.NotSent)),
        ),
      ]),
      config.default(),
    )
  let failures = [
    #(
      http_gun.send(
        live,
        base |> request.set_header("x-secret", "secret-value\r\nx: y"),
      ),
      error.InvalidRequest(error.InvalidHeader),
    ),
    #(
      http_gun.send(live, base |> request.set_path("/secret path")),
      error.InvalidRequest(error.InvalidTarget),
    ),
    #(http_gun.send(live, base), error.ResolutionFailed),
    #(
      http_gun.send(public_only, base |> request.set_host("127.0.0.1")),
      error.DestinationRejected(destination.AddressRefused(destination.Loopback)),
    ),
    #(http_gun.send(scripted, base), error.PlaybackMismatch(0)),
    #(
      http_gun.send(live |> http_gun.with_body_limit(-1, http_gun.Fail), base),
      error.InvalidRequest(error.InvalidBodyLimit),
    ),
  ]
  http_gun.stop(live)
  http_gun.stop(public_only)
  http_gun.stop(scripted)
  list.each(failures, fn(row) {
    let assert Error(failure) = row.0
    error.reason(failure) |> should.equal(row.1)
    let texts = [
      error.describe(failure),
      error.name(failure),
      json.to_string(error.to_json(failure)),
    ]
    list.each(texts, fn(text) {
      string.contains(string.lowercase(text), "secret") |> should.be_false
    })
  })
}

fn limit_kinds() -> List(error.LimitKind) {
  [
    error.RequestBodyBytes,
    error.RequestHeaderBytes,
    error.RequestHeaderCount,
    error.ResponseHeaderBytes,
    error.ResponseHeaderCount,
    error.BufferedBytes,
    error.ResponseBodyBytes,
    error.BatchBytes,
  ]
}

fn transport_causes() -> List(error.TransportCause) {
  [
    error.NameResolutionFailed,
    error.ConnectionRefused,
    error.CertificateRejected,
    error.TlsFailed,
    error.ConnectionReset,
    error.PeerClosed,
    error.PeerDraining,
    error.ProtocolError,
    error.HeaderLimitReached,
    error.TransportTimeout,
    error.UnexpectedProtocol,
    error.UnknownTransport,
  ]
}

fn problems() -> List(error.RequestProblem) {
  [
    error.BodyNotBytes,
    error.InvalidMethod,
    error.InvalidOrigin,
    error.InvalidTarget,
    error.InvalidHeader,
    error.InvalidBodyLimit,
    error.InvalidBatch,
  ]
}

fn rejections() -> List(destination.Rejection) {
  [
    destination.HostNotAllowed,
    destination.AddressRefused(destination.Public),
    destination.AddressRefused(destination.Loopback),
    destination.AddressRefused(destination.Private),
    destination.AddressRefused(destination.Reserved),
    destination.PlaintextRefused(destination.Public),
    destination.PlaintextRefused(destination.Loopback),
    destination.PlaintextRefused(destination.Private),
    destination.PlaintextRefused(destination.Reserved),
  ]
}

/// Every reason shape, each with its expected kind and name.
fn reasons() -> List(#(error.Reason, error.Kind, String)) {
  list.flatten([
    list.map(problems(), fn(p) {
      #(error.InvalidRequest(p), error.InvalidInput, "")
    }),
    list.map(rejections(), fn(r) {
      #(error.DestinationRejected(r), error.Refused, "")
    }),
    list.map(limit_kinds(), fn(k) {
      #(error.LimitExceeded(k, 2, 3), error.TooLarge, "")
    }),
    list.flat_map(transport_causes(), fn(c) {
      [
        #(error.ConnectionFailed(c), error.Network, ""),
        #(error.RequestFailed(c), error.Network, ""),
      ]
    }),
    [
      #(error.ClientClosed, error.Unavailable, "client_closed"),
      #(
        error.ViewDestinationRequired,
        error.Refused,
        "view_destination_required",
      ),
      #(error.AdmissionFull, error.Unavailable, "admission_full"),
      #(error.PoolTimeout, error.Unavailable, "pool_timeout"),
      #(error.RecordingClosed, error.Unavailable, "recording_closed"),
      #(error.ResolutionFailed, error.Network, "resolution_failed"),
      #(error.ConnectTimeout, error.TimedOut, "connect_timeout"),
      #(error.DeadlineExceeded, error.TimedOut, "deadline_exceeded"),
      #(error.IdleTimeout, error.TimedOut, "idle_timeout"),
      #(error.ReadConflict, error.Misuse, "read_conflict"),
      #(error.WrongOwner, error.Misuse, "wrong_owner"),
      #(error.Closed, error.CancelledLocally, "closed"),
      #(error.Cancelled, error.CancelledLocally, "cancelled"),
      #(error.PlaybackMismatch(2), error.Playback, "playback_mismatch"),
      #(error.PlaybackExhausted, error.Playback, "playback_exhausted"),
    ],
  ])
}

fn all_failures() -> List(error.Failure) {
  list.flat_map(reasons(), fn(row) {
    list.flat_map([error.NotSent, error.MaybeSent], fn(evidence) {
      let failure = error.new(row.0, evidence)
      [
        failure,
        error.with_status(failure, 200),
        error.with_status(failure, 429)
          |> error.with_headers([#("retry-after", "30"), #("link", "<a>")]),
      ]
    })
  })
}

pub fn kind_and_retryability_truth_table_test() {
  list.each(reasons(), fn(row) {
    let #(reason, kind, _) = row
    let transient = case kind {
      error.Unavailable | error.Network | error.TimedOut -> True
      error.InvalidInput
      | error.Refused
      | error.TooLarge
      | error.CancelledLocally
      | error.Misuse
      | error.Playback -> False
    }
    // #(evidence, idempotent, retryable)
    let table = [
      #(error.NotSent, False, transient),
      #(error.NotSent, True, transient),
      #(error.MaybeSent, False, False),
      #(error.MaybeSent, True, transient),
    ]
    list.each(table, fn(cell) {
      let failure = error.new(reason, cell.0)
      error.kind(failure) |> should.equal(kind)
      error.is_retryable(failure, idempotent: cell.1) |> should.equal(cell.2)
      // A status never changes the kind or retryability.
      let with_status = error.with_status(failure, 503)
      error.kind(with_status) |> should.equal(kind)
      error.is_retryable(with_status, idempotent: cell.1)
      |> should.equal(cell.2)
    })
  })
  // Spot checks against the documented contract.
  error.new(error.ConnectionFailed(error.ConnectionRefused), error.NotSent)
  |> error.is_retryable(idempotent: False)
  |> should.be_true
  error.new(error.RequestFailed(error.ConnectionReset), error.MaybeSent)
  |> error.is_retryable(idempotent: False)
  |> should.be_false
  error.new(error.RequestFailed(error.ConnectionReset), error.MaybeSent)
  |> error.is_retryable(idempotent: True)
  |> should.be_true
  error.new(error.LimitExceeded(error.ResponseBodyBytes, 1, 2), error.NotSent)
  |> error.is_retryable(idempotent: True)
  |> should.be_false
  error.new(
    error.DestinationRejected(destination.HostNotAllowed),
    error.NotSent,
  )
  |> error.is_retryable(idempotent: True)
  |> should.be_false
}

pub fn names_are_stable_identifiers_test() {
  [
    #(
      error.InvalidRequest(error.BodyNotBytes),
      "invalid_request.body_not_bytes",
    ),
    #(
      error.InvalidRequest(error.InvalidMethod),
      "invalid_request.invalid_method",
    ),
    #(
      error.InvalidRequest(error.InvalidOrigin),
      "invalid_request.invalid_origin",
    ),
    #(
      error.InvalidRequest(error.InvalidTarget),
      "invalid_request.invalid_target",
    ),
    #(
      error.InvalidRequest(error.InvalidHeader),
      "invalid_request.invalid_header",
    ),
    #(
      error.InvalidRequest(error.InvalidBodyLimit),
      "invalid_request.invalid_body_limit",
    ),
    #(error.InvalidRequest(error.InvalidBatch), "invalid_request.invalid_batch"),
    #(
      error.DestinationRejected(destination.HostNotAllowed),
      "destination_rejected.host_not_allowed",
    ),
    #(
      error.DestinationRejected(destination.AddressRefused(destination.Public)),
      "destination_rejected.public",
    ),
    #(
      error.DestinationRejected(destination.AddressRefused(destination.Loopback)),
      "destination_rejected.loopback",
    ),
    #(
      error.DestinationRejected(destination.AddressRefused(destination.Private)),
      "destination_rejected.private",
    ),
    #(
      error.DestinationRejected(destination.AddressRefused(destination.Reserved)),
      "destination_rejected.reserved",
    ),
    #(
      error.DestinationRejected(destination.PlaintextRefused(destination.Public)),
      "destination_rejected.plaintext_public",
    ),
    #(
      error.DestinationRejected(destination.PlaintextRefused(
        destination.Loopback,
      )),
      "destination_rejected.plaintext_loopback",
    ),
    #(
      error.LimitExceeded(error.RequestBodyBytes, 1, 2),
      "limit_exceeded.request_body_bytes",
    ),
    #(
      error.LimitExceeded(error.RequestHeaderBytes, 1, 2),
      "limit_exceeded.request_header_bytes",
    ),
    #(
      error.LimitExceeded(error.RequestHeaderCount, 1, 2),
      "limit_exceeded.request_header_count",
    ),
    #(
      error.LimitExceeded(error.ResponseHeaderBytes, 1, 2),
      "limit_exceeded.response_header_bytes",
    ),
    #(
      error.LimitExceeded(error.ResponseHeaderCount, 1, 2),
      "limit_exceeded.response_header_count",
    ),
    #(
      error.LimitExceeded(error.BufferedBytes, 1, 2),
      "limit_exceeded.buffered_bytes",
    ),
    #(
      error.LimitExceeded(error.ResponseBodyBytes, 1, 2),
      "limit_exceeded.response_body_bytes",
    ),
    #(error.LimitExceeded(error.BatchBytes, 1, 2), "limit_exceeded.batch_bytes"),
    #(
      error.ConnectionFailed(error.NameResolutionFailed),
      "connection_failed.name_resolution_failed",
    ),
    #(
      error.ConnectionFailed(error.ConnectionRefused),
      "connection_failed.connection_refused",
    ),
    #(
      error.ConnectionFailed(error.CertificateRejected),
      "connection_failed.certificate_rejected",
    ),
    #(error.ConnectionFailed(error.TlsFailed), "connection_failed.tls_failed"),
    #(
      error.RequestFailed(error.ConnectionReset),
      "request_failed.connection_reset",
    ),
    #(error.RequestFailed(error.PeerClosed), "request_failed.peer_closed"),
    #(error.RequestFailed(error.PeerDraining), "request_failed.peer_draining"),
    #(error.RequestFailed(error.ProtocolError), "request_failed.protocol_error"),
    #(
      error.RequestFailed(error.HeaderLimitReached),
      "request_failed.header_limit_reached",
    ),
    #(
      error.RequestFailed(error.TransportTimeout),
      "request_failed.transport_timeout",
    ),
    #(
      error.RequestFailed(error.UnexpectedProtocol),
      "request_failed.unexpected_protocol",
    ),
    #(
      error.RequestFailed(error.UnknownTransport),
      "request_failed.unknown_transport",
    ),
  ]
  |> list.append(
    list.filter_map(reasons(), fn(row) {
      case row.2 {
        "" -> Error(Nil)
        name -> Ok(#(row.0, name))
      }
    }),
  )
  |> list.each(fn(row) {
    error.name(error.new(row.0, error.NotSent)) |> should.equal(row.1)
    // Evidence and status are not part of the name.
    error.name(error.new(row.0, error.MaybeSent) |> error.with_status(200))
    |> should.equal(row.1)
  })
  // Every reason has a distinct name, apart from the detail fields.
  let names =
    list.map(reasons(), fn(row) { error.name(error.new(row.0, error.NotSent)) })
  list.length(list.unique(names)) |> should.equal(list.length(names))
}

pub fn json_roundtrips_every_reason_shape_test() {
  list.each(all_failures(), fn(failure) {
    json.to_string(error.to_json(failure))
    |> json.parse(error.decoder())
    |> should.equal(Ok(failure))
  })
  // The documented shape: limit with status, and positional mismatch.
  error.new(
    error.LimitExceeded(error.ResponseBodyBytes, 8_388_608, 8_388_609),
    error.MaybeSent,
  )
  |> error.with_status(200)
  |> error.to_json
  |> json.to_string
  |> should.equal(
    "{\"name\":\"limit_exceeded.response_body_bytes\",\"evidence\":\"maybe_sent\",\"status\":200,\"limit\":8388608,\"observed\":8388609}",
  )
  error.new(error.PlaybackMismatch(7), error.NotSent)
  |> error.to_json
  |> json.to_string
  |> should.equal(
    "{\"name\":\"playback_mismatch\",\"evidence\":\"not_sent\",\"position\":7}",
  )
  let rejected =
    error.new(
      error.DestinationRejected(destination.AddressRefused(destination.Reserved)),
      error.NotSent,
    )
  json.to_string(error.to_json(rejected))
  |> should.equal(
    "{\"name\":\"destination_rejected.reserved\",\"evidence\":\"not_sent\"}",
  )
  let refused =
    error.new(error.ConnectionFailed(error.ConnectionRefused), error.NotSent)
  json.to_string(error.to_json(refused))
  |> json.parse(error.decoder())
  |> should.equal(Ok(refused))
  error.status(refused) |> should.equal(None)
}

pub fn decoder_rejects_unknown_names_and_shapes_test() {
  [
    "{\"name\":\"bogus\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"client_closed.extra\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"client_closed\",\"evidence\":\"maybe\"}",
    "{\"name\":\"client_closed\"}",
    "{\"evidence\":\"not_sent\"}",
    "{\"name\":\"invalid_request\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"invalid_request.bogus\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"destination_rejected\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"destination_rejected.bogus\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"connection_failed.bogus\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"request_failed\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"limit_exceeded.bogus\",\"evidence\":\"not_sent\",\"limit\":1,\"observed\":2}",
    "{\"name\":\"limit_exceeded.response_body_bytes\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"limit_exceeded.response_body_bytes\",\"evidence\":\"not_sent\",\"limit\":1}",
    "{\"name\":\"limit_exceeded.response_body_bytes\",\"evidence\":\"not_sent\",\"limit\":-1,\"observed\":2}",
    "{\"name\":\"playback_mismatch\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"playback_mismatch\",\"evidence\":\"not_sent\",\"position\":-1}",
    "{\"name\":\"fixture_corrupt\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"read_timeout\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"client_closed\",\"evidence\":\"not_sent\",\"status\":\"200\"}",
    "{\"reason\":\"limit\",\"detail\":\"collection\",\"count\":2,\"evidence\":\"may_have_been_sent\"}",
  ]
  |> list.each(fn(text) { json.parse(text, error.decoder()) |> should.be_error })
}

pub fn typed_failures_roundtrip_all_categories_test() {
  let req = request.new() |> request.set_body(<<>>)
  let failures = all_failures()
  let tape =
    testing.script(
      list.map(failures, fn(f) { testing.exchange(req, testing.Reject(f)) }),
    )
  let text = cassette.encode(tape)
  let assert Ok(parsed) = cassette.parse(text, 1_000_000)
  cassette.encode(parsed) |> should.equal(text)
  let assert Ok(client) = testing.playback(parsed, config.default())
  list.each(failures, fn(expected) {
    http_gun.send(client, req) |> should.equal(Error(expected))
  })
  http_gun.stop(client)
}

pub fn obsolete_fixture_errors_are_rejected_test() {
  // Schema 1 files are no longer read.
  let text =
    "{\"http_gun\":1,\"exchanges\":[{\"request\":{\"url\":\"http://localhost/\",\"method\":\"GET\",\"headers\":[],\"body\":{\"bytes\":0,\"base64\":\"\"}},\"reply\":{\"kind\":\"reject\",\"failure\":{\"reason\":\"limit\",\"detail\":\"collection\",\"count\":2,\"evidence\":\"may_have_been_sent\"}}}]}"
  cassette.parse(text, 10_000)
  |> should.equal(Error(cassette.UnsupportedVersion(1)))
  // A schema 2 file carrying the obsolete failure shape is corrupt.
  let req = request.new() |> request.set_body(<<>>)
  let failure = error.new(error.ClientClosed, error.NotSent)
  let encoded =
    cassette.encode(
      testing.script([testing.exchange(req, testing.Reject(failure))]),
    )
  let current = json.to_string(error.to_json(failure))
  string.contains(encoded, current) |> should.be_true
  [
    "{\"reason\":\"limit\",\"detail\":\"collection\",\"count\":2,\"evidence\":\"may_have_been_sent\"}",
    "{\"name\":\"fixture_exhausted\",\"evidence\":\"not_sent\"}",
    "{\"name\":\"client_closed\",\"evidence\":\"may_have_been_sent\"}",
  ]
  |> list.each(fn(obsolete) {
    cassette.parse(string.replace(encoded, current, obsolete), 10_000)
    |> should.equal(Error(cassette.Corrupt))
  })
}

@external(erlang, "http_gun_test_server", "unused_port")
fn unused_port() -> Int

pub fn connection_refusal_is_typed_and_not_submitted_test() {
  let assert Ok(client) =
    http_gun.start(config.default() |> config.allow_loopback)
  let req =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_host("localhost")
    |> request.set_port(unused_port())
    |> request.set_body(<<>>)
  let assert Error(failure) = http_gun.send(client, req)
  failure
  |> should.equal(error.new(
    error.ConnectionFailed(error.ConnectionRefused),
    error.NotSent,
  ))
  error.kind(failure) |> should.equal(error.Network)
  error.is_retryable(failure, idempotent: False) |> should.be_true
  http_gun.stop(client)
}

pub fn response_header_count_limit_reports_count_not_bytes_test() {
  let req = request.new() |> request.set_body(<<>>)
  let settings = config.default() |> config.with_max_header_count(1)
  let exchange =
    testing.exchange(
      req,
      testing.Respond(
        response.Response(200, [#("x", "a"), #("y", "b")], []),
        testing.Finished([]),
      ),
    )
  let assert Ok(client) = testing.playback(testing.script([exchange]), settings)
  let assert Error(failure) = http_gun.send(client, req)
  error.reason(failure)
  |> should.equal(error.LimitExceeded(error.ResponseHeaderCount, 1, 2))
  error.evidence(failure) |> should.equal(error.MaybeSent)
  http_gun.stop(client)
}

pub fn limit_fixture_requires_an_observed_size_test() {
  let req = request.new() |> request.set_body(<<>>)
  let tape =
    testing.script([
      testing.exchange(
        req,
        testing.Reject(error.new(
          error.LimitExceeded(error.ResponseBodyBytes, 2, 3),
          error.MaybeSent,
        )),
      ),
    ])
  let encoded = cassette.encode(tape)
  string.contains(encoded, "\"http_gun\":2") |> should.be_true
  string.contains(encoded, "\"observed\":3") |> should.be_true
  let corrupt = Error(cassette.Corrupt)
  list.each(
    [
      #("\"observed\":3", "\"observed\":null"),
      #("\"observed\":3", "\"observed\":-1"),
      #(",\"observed\":3", ""),
      #("response_body_bytes", "other_limit"),
    ],
    fn(change) {
      cassette.parse(string.replace(encoded, change.0, change.1), 10_000)
      |> should.equal(corrupt)
    },
  )
  cassette.parse(
    string.replace(encoded, "\"http_gun\":2", "\"http_gun\":3"),
    10_000,
  )
  |> should.equal(Error(cassette.UnsupportedVersion(3)))
}

@external(erlang, "http_gun_test_server", "late_monitor_refusal")
fn late_monitor_refusal(port: Int) -> #(error.TransportCause, Bool)

pub fn connection_refusal_survives_monitor_after_gun_exit_test() {
  let #(cause, monitored_after_exit) = late_monitor_refusal(unused_port())
  monitored_after_exit |> should.be_true
  cause |> should.equal(error.ConnectionRefused)
}
