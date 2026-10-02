import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import http_gun
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/error
import http_gun/fixture
import http_gun/recording
import http_gun/request_options
import http_gun/testing

type Listener

pub fn main() {
  let _ = default_refuses_loopback_before_connecting_test()
  let _ = private_resolution_is_rejected_test()
  let _ = pinned_tls_preserves_original_identity_test()
  let _ = ip_literal_tls_checks_ip_san_test()
  let _ = resolution_lifetime_cleanup_test()
  let _ = slow_resolution_does_not_block_other_origins_test()
  let _ = throwing_resolver_is_typed_and_does_not_kill_pool_test()
}

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

pub fn private_resolution_is_rejected_test() {
  let c = config.default()
  let c =
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        resolver: Some(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) }),
      ),
    )
  let assert Ok(client) = http_gun.start(c)
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(server()))
  let actual = http_gun.send(client, request.set_body(req, <<>>))
  let _ = http_gun.stop(client)
  actual
  |> should.equal(
    Error(error.Failure(error.DestinationRejected, error.NotSubmitted)),
  )
}

@external(erlang, "http_gun_destination_test_ffi", "listen")
fn listen() -> #(Int, Listener)

@external(erlang, "http_gun_destination_test_ffi", "connected")
fn connected(listener: Listener) -> Bool

pub fn default_refuses_loopback_before_connecting_test() {
  let #(port, listener) = listen()
  let defaults = config.default()
  let assert Ok(client) =
    http_gun.start(config.Config(..defaults, deadline_ms: 300))
  let assert Ok(req) = request.to("http://127.0.0.1:" <> int.to_string(port))
  let result = http_gun.send(client, request.set_body(req, <<>>))
  let observed = connected(listener)
  let _ = http_gun.stop(client)
  let assert Error(failure) = result
  failure.evidence |> should.equal(error.NotSubmitted)
  observed |> should.be_false
}

pub fn allow_loopback_helper_admits_only_loopback_test() {
  let c = config.default()
  let base =
    config.Config(
      ..c,
      deadline_ms: 1000,
      destination: destination.Policy(
        ..c.destination,
        allowed_hosts: Some(["localhost", "127.0.0.1"]),
      ),
    )
  let opened = config.allow_loopback(base)
  opened
  |> should.equal(
    config.Config(
      ..base,
      destination: destination.Policy(..base.destination, allow_loopback: True),
    ),
  )
  opened.destination.allow_private |> should.be_false
  let assert Ok(client) = http_gun.start(opened)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let _ = http_gun.stop(client)
  let private =
    config.Config(
      ..opened,
      destination: destination.Policy(
        ..opened.destination,
        resolver: Some(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) }),
      ),
    )
  let assert Ok(client) = http_gun.start(private)
  http_gun.send(client, local_request(server(), "localhost"))
  |> should.equal(
    Error(error.Failure(error.DestinationRejected, error.NotSubmitted)),
  )
  let _ = http_gun.stop(client)
}

pub fn mixed_empty_failed_and_disallowed_hosts_test() {
  let defaults = config.default()
  let cases = [
    #(
      Some(fn(_, _) {
        Ok([destination.Ipv4(8, 8, 8, 8), destination.Ipv4(169, 254, 169, 254)])
      }),
      None,
      error.DestinationRejected,
    ),
    #(Some(fn(_, _) { Ok([]) }), None, error.ResolutionFailed),
    #(Some(fn(_, _) { Error(Nil) }), None, error.ResolutionFailed),
    #(
      Some(fn(_, _) { panic as "resolver must not run for disallowed host" }),
      Some(["other.test"]),
      error.DestinationRejected,
    ),
  ]
  list.each(cases, fn(row) {
    let #(port, listener) = listen()
    let c =
      config.Config(
        ..defaults,
        destination: destination.Policy(
          ..defaults.destination,
          resolver: row.0,
          allowed_hosts: row.1,
        ),
      )
    let assert Ok(client) = http_gun.start(c)
    let actual = http_gun.send(client, local_request(port, "localhost"))
    let seen = connected(listener)
    let _ = http_gun.stop(client)
    actual |> should.equal(Error(error.Failure(row.2, error.NotSubmitted)))
    seen |> should.be_false
  })
}

fn local_request(port: Int, host: String) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(http.Http)
  |> request.set_host(host)
  |> request.set_port(port)
  |> request.set_body(<<>>)
}

fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}

type Counter

@external(erlang, "http_gun_destination_test_ffi", "counter")
fn counter() -> Counter

@external(erlang, "http_gun_destination_test_ffi", "increment")
fn increment(counter: Counter) -> Int

@external(erlang, "http_gun_destination_test_ffi", "count")
fn count(counter: Counter) -> Int

pub fn checked_answer_is_pinned_and_reused_test() {
  let calls = counter()
  let c = local_config()
  let settings =
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        allowed_hosts: Some(["LOCALHOST"]),
        resolver: Some(fn(_, _) {
          case increment(calls) {
            1 -> Ok([destination.Ipv4(127, 0, 0, 1)])
            _ -> Ok([destination.Ipv4(10, 0, 0, 1)])
          }
        }),
      ),
    )
  let assert Ok(client) = http_gun.start(settings)
  let req = local_request(server(), "localhost")
  let assert Ok(first) = http_gun.send(client, req)
  let assert Ok(second) = http_gun.send(client, req)
  response.get_header(first.response, "x-connection")
  |> should.equal(response.get_header(second.response, "x-connection"))
  count(calls) |> should.equal(1)
  let _ = http_gun.stop(client)
  // A new client/connection cannot reuse a formerly permitted answer.
  let assert Ok(next) = http_gun.start(settings)
  http_gun.send(next, req)
  |> should.equal(
    Error(error.Failure(error.DestinationRejected, error.NotSubmitted)),
  )
  count(calls) |> should.equal(2)
  let _ = http_gun.stop(next)
}

pub fn literals_bypass_resolver_and_loopback_requires_opt_in_test() {
  let c = local_config()
  let settings =
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        resolver: Some(fn(_, _) { panic as "literal must not resolve" }),
      ),
    )
  let assert Ok(client) = http_gun.start(settings)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let _ = http_gun.stop(client)
}

pub fn policy_validation_is_pure_test() {
  let c = config.default()
  config.validate(
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        allowed_hosts: Some([""]),
      ),
    ),
  )
  |> should.be_error
  config.validate(
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        allowed_hosts: Some([]),
        resolver: Some(fn(_, _) { panic as "validation is pure" }),
      ),
    ),
  )
  |> should.be_ok
}

pub fn address_classification_test() {
  let cases = [
    #(destination.Ipv4(8, 8, 8, 8), destination.Public),
    #(destination.Ipv4(127, 255, 0, 2), destination.Loopback),
    #(destination.Ipv4(10, 0, 0, 7), destination.Private),
    #(destination.Ipv4(172, 16, 0, 1), destination.Private),
    #(destination.Ipv4(172, 31, 255, 255), destination.Private),
    #(destination.Ipv4(172, 32, 0, 1), destination.Public),
    #(destination.Ipv4(192, 168, 1, 2), destination.Private),
    #(destination.Ipv4(100, 64, 0, 1), destination.Private),
    #(destination.Ipv4(100, 127, 255, 255), destination.Private),
    #(destination.Ipv4(100, 128, 0, 1), destination.Public),
    #(destination.Ipv4(100, 100, 100, 200), destination.Reserved),
    #(destination.Ipv4(0, 0, 0, 0), destination.Reserved),
    #(destination.Ipv4(169, 254, 169, 254), destination.Reserved),
    #(destination.Ipv4(224, 0, 0, 1), destination.Reserved),
    #(destination.Ipv4(240, 0, 0, 1), destination.Reserved),
    #(destination.Ipv4(255, 255, 255, 255), destination.Reserved),
    #(destination.Ipv4(192, 0, 0, 9), destination.Reserved),
    #(destination.Ipv4(192, 0, 2, 1), destination.Reserved),
    #(destination.Ipv4(192, 88, 99, 1), destination.Reserved),
    #(destination.Ipv4(198, 51, 100, 1), destination.Reserved),
    #(destination.Ipv4(203, 0, 113, 1), destination.Reserved),
    #(destination.Ipv4(198, 18, 0, 1), destination.Reserved),
    #(destination.Ipv4(198, 19, 255, 1), destination.Reserved),
    #(destination.Ipv4(256, 1, 1, 1), destination.Reserved),
    #(destination.Ipv4(-1, 1, 1, 1), destination.Reserved),
    #(destination.Ipv6(0, 0, 0, 0, 0, 0, 0, 1), destination.Loopback),
    #(destination.Ipv6(0, 0, 0, 0, 0, 0, 0, 0), destination.Reserved),
    #(destination.Ipv6(0xFE80, 0, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0xFF02, 0, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0xFC00, 0, 0, 0, 0, 0, 0, 1), destination.Private),
    #(destination.Ipv6(0xFDFF, 0, 0, 0, 0, 0, 0, 1), destination.Private),
    #(
      destination.Ipv6(0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254),
      destination.Reserved,
    ),
    #(destination.Ipv6(0x2001, 0xDB8, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 2, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0x10, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0x1F, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0x20, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0x2F, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x2001, 0x30, 0, 0, 0, 0, 0, 1), destination.Public),
    #(destination.Ipv6(0x2002, 0, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x3FFF, 0xFFF, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(destination.Ipv6(0x3FFF, 0x1000, 0, 0, 0, 0, 0, 1), destination.Public),
    #(destination.Ipv6(0x100, 0, 0, 0, 0, 0, 0, 1), destination.Reserved),
    #(
      destination.Ipv6(0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111),
      destination.Public,
    ),
    #(destination.Ipv6(0, 0, 0, 0, 0, 0xFFFF, 0x7F00, 1), destination.Loopback),
    #(
      destination.Ipv6(0, 0, 0, 0, 0, 0xFFFF, 0xA9FE, 0xA9FE),
      destination.Reserved,
    ),
    #(destination.Ipv6(0x64, 0xFF9B, 0, 0, 0, 0, 0xA00, 7), destination.Private),
    #(
      destination.Ipv6(0x64, 0xFF9B, 0, 0, 0, 0, 0x808, 0x808),
      destination.Public,
    ),
    #(
      destination.Ipv6(0x64, 0xFF9B, 0, 0, 0, 0, 0x6464, 0x64C8),
      destination.Reserved,
    ),
  ]
  list.each(cases, fn(row) {
    destination.classify(row.0) |> should.equal(row.1)
  })
}

@external(erlang, "http_gun_tls_test_server", "start")
fn tls_hostname() -> Int

@external(erlang, "http_gun_tls_test_server", "ip")
fn tls_ip() -> Int

pub fn pinned_tls_preserves_original_identity_test() {
  let c = local_config()
  let settings =
    config.Config(
      ..c,
      trust: config.CustomCa("test/fixtures/ca.crt"),
      destination: destination.Policy(
        ..c.destination,
        resolver: Some(fn(_, _) { Ok([destination.Ipv4(127, 0, 0, 1)]) }),
      ),
    )
  let assert Ok(client) = http_gun.start(settings)
  let assert Ok(reply) =
    http_gun.send(
      client,
      local_request(tls_hostname(), "localhost")
        |> request.set_scheme(http.Https),
    )
  reply.response.status |> should.equal(200)
  let assert Error(failure) =
    http_gun.send(
      client,
      local_request(tls_hostname(), "wrong.invalid")
        |> request.set_scheme(http.Https),
    )
  failure
  |> should.equal(error.Failure(
    error.ConnectionFailed(error.CertificateRejected),
    error.NotSubmitted,
  ))
  let _ = http_gun.stop(client)
}

pub fn ip_literal_tls_checks_ip_san_test() {
  let c = local_config()
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, trust: config.CustomCa("test/fixtures/ip_ca.crt")),
    )
  let assert Ok(reply) =
    http_gun.send(
      client,
      local_request(tls_ip(), "127.0.0.1") |> request.set_scheme(http.Https),
    )
  reply.response.status |> should.equal(200)
  let _ = http_gun.stop(client)
  let assert Ok(client) =
    http_gun.start(
      config.Config(..c, trust: config.CustomCa("test/fixtures/ca.crt")),
    )
  let assert Error(failure) =
    http_gun.send(
      client,
      local_request(tls_hostname(), "127.0.0.1")
        |> request.set_scheme(http.Https),
    )
  failure
  |> should.equal(error.Failure(
    error.ConnectionFailed(error.CertificateRejected),
    error.NotSubmitted,
  ))
  let _ = http_gun.stop(client)
}

pub fn reserved_never_allowed_and_public_can_be_disabled_test() {
  let c = local_config()
  list.each(
    [
      destination.Ipv4(100, 100, 100, 200),
      destination.Ipv6(0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254),
      destination.Ipv4(8, 8, 8, 8),
    ],
    fn(address) {
      let settings =
        config.Config(
          ..c,
          destination: destination.Policy(
            ..c.destination,
            allow_private: True,
            allow_public: False,
            resolver: Some(fn(_, _) { Ok([address]) }),
          ),
        )
      let #(port, listener) = listen()
      let assert Ok(client) = http_gun.start(settings)
      http_gun.send(client, local_request(port, "localhost"))
      |> should.equal(
        Error(error.Failure(error.DestinationRejected, error.NotSubmitted)),
      )
      connected(listener) |> should.be_false
      let _ = http_gun.stop(client)
    },
  )
}

pub fn resolution_lifetime_cleanup_test() {
  list.each(
    ["cancel", "deadline", "caller_death", "shutdown", "client_death"],
    fn(mode) {
      let entered = process.new_subject()
      let ready = process.new_subject()
      let c = local_config()
      let settings =
        config.Config(
          ..c,
          deadline_ms: case mode {
            "deadline" -> 150
            _ -> 5000
          },
          destination: destination.Policy(
            ..c.destination,
            resolver: Some(fn(_, budget) {
              { budget > 0 } |> should.be_true
              process.send(entered, process.self())
              let forever: process.Subject(Nil) = process.new_subject()
              let _ = process.receive_forever(forever)
              Ok([destination.Ipv4(127, 0, 0, 1)])
            }),
          ),
        )
      let service =
        process.spawn_unlinked(fn() {
          let assert Ok(client) = http_gun.start(settings)
          process.send(ready, client)
          let forever: process.Subject(Nil) = process.new_subject()
          process.receive_forever(forever)
        })
      let assert Ok(client) = process.receive(ready, 1000)
      let #(port, listener) = listen()
      let result = process.new_subject()
      let assert Ok(Nil) =
        cancellation.with_token(fn(token) {
          let caller =
            process.spawn_unlinked(fn() {
              process.send(
                result,
                http_gun.send_with_options(
                  client,
                  local_request(port, "localhost"),
                  request_options.Options(
                    ..request_options.default(),
                    cancellation: Some(token),
                  ),
                ),
              )
            })
          let assert Ok(resolver) = process.receive(entered, 1000)
          let monitor = process.monitor(resolver)
          case mode {
            "cancel" -> cancellation.cancel(token)
            "caller_death" -> process.kill(caller)
            "shutdown" -> {
              let _ = http_gun.stop(client)
              Nil
            }
            "client_death" -> process.kill(service)
            _ -> Nil
          }
          process.new_selector()
          |> process.select_specific_monitor(monitor, fn(_) { Nil })
          |> process.selector_receive(1500)
          |> should.equal(Ok(Nil))
          process.demonitor_process(monitor)
          case mode {
            "caller_death" -> Nil
            _ -> {
              let assert Ok(Error(failure)) = process.receive(result, 1500)
              let expected = case mode {
                "cancel" -> error.Failure(error.Cancelled, error.NotSubmitted)
                "deadline" ->
                  error.Failure(error.DeadlineExceeded, error.NotSubmitted)
                "client_death" ->
                  error.Failure(error.ClientClosed, error.MayHaveBeenSent)
                _ -> error.Failure(error.ClientClosed, error.NotSubmitted)
              }
              failure |> should.equal(expected)
            }
          }
        })
      connected(listener) |> should.be_false
      let _ = http_gun.stop(client)
      process.kill(service)
    },
  )
}

pub fn slow_resolution_does_not_block_other_origins_test() {
  let entered = process.new_subject()
  let c = local_config()
  let settings =
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        resolver: Some(fn(_, _) {
          process.send(entered, Nil)
          let forever: process.Subject(Nil) = process.new_subject()
          let _ = process.receive_forever(forever)
          Ok([])
        }),
      ),
    )
  let assert Ok(client) = http_gun.start(settings)
  let result = process.new_subject()
  let assert Ok(Nil) =
    cancellation.with_token(fn(token) {
      let _ =
        process.spawn_unlinked(fn() {
          process.send(
            result,
            http_gun.send_with_options(
              client,
              local_request(1, "localhost"),
              request_options.Options(
                ..request_options.default(),
                cancellation: Some(token),
              ),
            ),
          )
        })
      process.receive(entered, 1000) |> should.equal(Ok(Nil))
      let assert Ok(reply) =
        http_gun.send(client, local_request(server(), "127.0.0.1"))
      reply.response.status |> should.equal(200)
      cancellation.cancel(token)
      let assert Ok(Error(failure)) = process.receive(result, 1000)
      failure.reason |> should.equal(error.Cancelled)
    })
  let _ = http_gun.stop(client)
}

pub fn throwing_resolver_is_typed_and_does_not_kill_pool_test() {
  let c = local_config()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        destination: destination.Policy(
          ..c.destination,
          resolver: Some(fn(_, _) { panic as "injected resolver failure" }),
        ),
      ),
    )
  http_gun.send(client, local_request(1, "localhost"))
  |> should.equal(
    Error(error.Failure(error.ResolutionFailed, error.NotSubmitted)),
  )
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.status |> should.equal(200)
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

pub fn recording_enforces_destination_and_offline_modes_never_resolve_test() {
  let c = config.default()
  let settings =
    config.Config(
      ..c,
      destination: destination.Policy(
        ..c.destination,
        resolver: Some(fn(_, _) { panic as "offline cannot resolve" }),
      ),
    )
  let req = local_request(1, "127.0.0.1")
  let file = temp_path()
  let assert Ok(recorded) = cassette.record(settings, file, recording.default())
  let failure = error.Failure(error.DestinationRejected, error.NotSubmitted)
  http_gun.send(recorded.client, req) |> should.equal(Error(failure))
  recording.finish_wait(recorded.recording, 2000) |> should.equal(Ok(file))
  let _ = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(file, 10_000)
  let assert Ok(replay) = cassette.playback(tape, settings)
  http_gun.send(replay, req |> request.set_path("/mismatch"))
  |> should.equal(
    Error(error.Failure(error.FixtureMismatch(0), error.NotSubmitted)),
  )
  http_gun.send(replay, req) |> should.equal(Error(failure))
  let _ = http_gun.stop(replay)
  remove_fixture(file)
  let assert Ok(script) =
    testing.start(settings, [
      fixture.Exchange(
        req,
        fixture.Respond(
          response.new(200) |> response.set_body([<<"offline":utf8>>]),
          fixture.Complete([]),
        ),
      ),
    ])
  let assert Ok(reply) = http_gun.send(script, req)
  reply.response.body |> should.equal(<<"offline":utf8>>)
  let _ = http_gun.stop(script)
}
