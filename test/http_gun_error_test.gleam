import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/string
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/fixture
import http_gun/testing

pub fn typed_collection_limit_reports_observed_bytes_test() {
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.new(200) |> response.set_body([<<0, 255, 128>>]),
        fixture.Complete([]),
      ),
    )
  let assert Ok(client) = testing.start(config.default(), [exchange])
  let assert Ok(reply) = http_gun.open(client, req)
  body.collect(reply.body, 2)
  |> should.equal(
    Error(error.Failure(
      error.LimitExceeded(error.CollectedBodyBytes, 2, 3),
      error.MayHaveBeenSent,
    )),
  )
  let _ = http_gun.stop(client)
}

pub fn descriptions_omit_free_form_details_test() {
  error.describe(error.Failure(
    error.InvalidRequest("secret URL query and body"),
    error.NotSubmitted,
  ))
  |> should.equal("Invalid HTTP request; not submitted")
  error.describe(error.Failure(
    error.InvalidConfig("secret CA path"),
    error.NotSubmitted,
  ))
  |> should.equal("Invalid client configuration; not submitted")
  error.describe(error.Failure(
    error.CaptureFailed("secret fixture path"),
    error.MayHaveBeenSent,
  ))
  |> should.equal("Recording unavailable; request may have been sent")
}

pub fn typed_failures_roundtrip_all_categories_test() {
  let kinds = [
    error.RequestBodyBytes,
    error.RequestHeaderBytes,
    error.RequestHeaderCount,
    error.ResponseHeaderBytes,
    error.ResponseHeaderCount,
    error.ResponseChunkBytes,
    error.ResponseQueueBytes,
    error.CollectedBodyBytes,
    error.FixtureBytes,
  ]
  let causes = [
    error.NameResolutionFailed,
    error.ConnectionRefused,
    error.CertificateRejected,
    error.TlsFailed,
    error.ConnectionReset,
    error.PeerClosed,
    error.PeerDraining,
    error.ProtocolError,
    error.TransportTimeout,
    error.UnexpectedProtocol,
    error.UnknownTransport,
  ]
  let operations = [
    error.OpenFile,
    error.ReadFile,
    error.WriteFile,
    error.CloseFile,
    error.CreateDirectory,
    error.SetPermissions,
    error.PublishFixture,
  ]
  let file_causes = [
    error.FileMissing,
    error.AlreadyExists,
    error.PermissionDenied,
    error.NoSpace,
    error.ReadOnlyFilesystem,
    error.NotDirectory,
    error.IsDirectory,
    error.CrossFilesystem,
    error.UnknownIoFailure,
  ]
  let reasons =
    list.append(
      list.map(kinds, fn(k) { error.LimitExceeded(k, 2, 3) }),
      list.append(
        list.flat_map(causes, fn(c) {
          [error.ConnectionFailed(c), error.RequestFailed(c)]
        }),
        list.append(
          list.flat_map(operations, fn(o) {
            list.map(file_causes, fn(c) { error.FixtureIo(o, c) })
          }),
          [
            error.InvalidConfig("detail"),
            error.InvalidRequest("detail"),
            error.ClientClosed,
            error.AdmissionFull,
            error.DestinationRejected,
            error.ResolutionFailed,
            error.DeadlineExceeded,
            error.ReadTimeout,
            error.ReadConflict,
            error.WrongOwner,
            error.Closed,
            error.Cancelled,
            error.FixtureMissing,
            error.FixtureCorrupt,
            error.FixtureVersion(42),
            error.FixtureExhausted,
            error.FixtureMismatch(2),
            error.CaptureFailed("detail"),
          ],
        ),
      ),
    )
  let req = request.new() |> request.set_body(<<>>)
  let failures =
    list.flat_map(reasons, fn(reason) {
      [
        error.Failure(reason, error.NotSubmitted),
        error.Failure(reason, error.MayHaveBeenSent),
      ]
    })
  let assert Ok(tape) =
    cassette.new(
      list.map(failures, fn(f) { fixture.Exchange(req, fixture.Reject(f)) }),
    )
  let text = cassette.encode(tape)
  let assert Ok(parsed) = cassette.parse(text, 100_000)
  cassette.encode(parsed) |> should.equal(text)
  let assert Ok(client) = cassette.playback(parsed, config.default())
  list.each(failures, fn(expected) {
    http_gun.send(client, req) |> should.equal(Error(expected))
  })
  let _ = http_gun.stop(client)
}

pub fn obsolete_fixture_errors_are_rejected_test() {
  let text =
    "{\"http_gun\":1,\"exchanges\":[{\"request\":{\"url\":\"http://localhost/\",\"method\":\"GET\",\"headers\":[],\"body\":{\"bytes\":0,\"base64\":\"\"}},\"reply\":{\"kind\":\"reject\",\"failure\":{\"reason\":\"limit\",\"detail\":\"collection\",\"count\":2,\"evidence\":\"may_have_been_sent\"}}}]}"
  cassette.parse(text, 10_000)
  |> should.equal(
    Error(error.Failure(error.FixtureCorrupt, error.NotSubmitted)),
  )
}

@external(erlang, "http_gun_test_server", "unused_port")
fn unused_port() -> Int

pub fn connection_refusal_is_typed_and_not_submitted_test() {
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..config.default(),
        destination: destination.Policy(
          ..destination.default(),
          allow_loopback: True,
        ),
      ),
    )
  let req =
    request.new()
    |> request.set_scheme(http.Http)
    |> request.set_host("localhost")
    |> request.set_port(unused_port())
    |> request.set_body(<<>>)
  let assert Error(failure) = http_gun.send(client, req)
  failure
  |> should.equal(error.Failure(
    error.ConnectionFailed(error.ConnectionRefused),
    error.NotSubmitted,
  ))
  let _ = http_gun.stop(client)
}

pub fn response_header_count_limit_reports_count_not_bytes_test() {
  let req = request.new() |> request.set_body(<<>>)
  let c = config.default()
  let settings =
    config.Config(..c, limits: config.Limits(..c.limits, header_count: 1))
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.Response(200, [#("x", "a"), #("y", "b")], []),
        fixture.Complete([]),
      ),
    )
  let assert Ok(client) = testing.start(settings, [exchange])
  http_gun.send(client, req)
  |> should.equal(
    Error(error.Failure(
      error.LimitExceeded(error.ResponseHeaderCount, 1, 2),
      error.MayHaveBeenSent,
    )),
  )
  let _ = http_gun.stop(client)
}

pub fn limit_fixture_requires_an_observed_size_test() {
  let req = request.new() |> request.set_body(<<>>)
  let assert Ok(tape) =
    cassette.new([
      fixture.Exchange(
        req,
        fixture.Reject(error.Failure(
          error.LimitExceeded(error.CollectedBodyBytes, 2, 3),
          error.MayHaveBeenSent,
        )),
      ),
    ])
  let encoded = cassette.encode(tape)
  string.contains(encoded, "\"http_gun\":1") |> should.be_true
  let corrupt = Error(error.Failure(error.FixtureCorrupt, error.NotSubmitted))
  list.each(
    [
      #("\"observed\":3", "\"observed\":null"),
      #("\"observed\":3", "\"observed\":-1"),
      #("\"observed\":3,", ""),
      #("collected_body_bytes", "other_limit"),
    ],
    fn(change) {
      cassette.parse(string.replace(encoded, change.0, change.1), 10_000)
      |> should.equal(corrupt)
    },
  )
  cassette.parse(
    string.replace(encoded, "\"http_gun\":1", "\"http_gun\":2"),
    10_000,
  )
  |> should.equal(
    Error(error.Failure(error.FixtureVersion(2), error.NotSubmitted)),
  )
}
