import gleam/erlang/process
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleeunit/should
import http_gun
import http_gun/cancellation
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/error
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

fn rejected(rejection: destination.Rejection) -> error.Failure {
  error.new(error.DestinationRejected(rejection), error.NotSent)
}

pub fn private_resolution_is_rejected_test() {
  let c =
    config.default()
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) })
  let assert Ok(client) = http_gun.start(c)
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(server()))
  let actual = http_gun.send(client, request.set_body(req, <<>>))
  http_gun.stop(client)
  actual
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Private))),
  )
}

@external(erlang, "http_gun_destination_test_ffi", "listen")
fn listen() -> #(Int, Listener)

@external(erlang, "http_gun_destination_test_ffi", "connected")
fn connected(listener: Listener) -> Bool

@external(erlang, "http_gun_destination_test_ffi", "echo_authority")
fn echo_authority(ipv6: Bool) -> Int

pub fn default_refuses_loopback_before_connecting_test() {
  let #(port, listener) = listen()
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.with_request_timeout(config.Milliseconds(300)),
    )
  let assert Ok(req) = request.to("http://127.0.0.1:" <> int.to_string(port))
  let result = http_gun.send(client, request.set_body(req, <<>>))
  let observed = connected(listener)
  http_gun.stop(client)
  let assert Error(failure) = result
  error.evidence(failure) |> should.equal(error.NotSent)
  failure
  |> should.equal(rejected(destination.AddressRefused(destination.Loopback)))
  observed |> should.be_false
}

pub fn allow_loopback_helper_admits_only_loopback_test() {
  let hosts =
    destination.default()
    |> destination.only_hosts(["localhost", "127.0.0.1"])
  let base =
    config.default()
    |> config.with_request_timeout(config.Milliseconds(1000))
    |> config.with_destination(hosts)
  let opened = config.allow_loopback(base)
  // allow_loopback keeps every other destination setting.
  opened
  |> should.equal(config.with_destination(
    base,
    destination.allow_loopback(hosts),
  ))
  let assert Ok(client) = http_gun.start(opened)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
  // Private addresses stay refused.
  let private =
    opened
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) })
  let assert Ok(client) = http_gun.start(private)
  http_gun.send(client, local_request(server(), "localhost"))
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Private))),
  )
  http_gun.stop(client)
}

pub fn mixed_empty_failed_and_disallowed_hosts_test() {
  let cases = [
    #(
      fn(_, _) {
        Ok([destination.Ipv4(8, 8, 8, 8), destination.Ipv4(169, 254, 169, 254)])
      },
      destination.default(),
      error.DestinationRejected(destination.AddressRefused(destination.Reserved)),
    ),
    #(fn(_, _) { Ok([]) }, destination.default(), error.ResolutionFailed),
    #(fn(_, _) { Error(Nil) }, destination.default(), error.ResolutionFailed),
    #(
      fn(_, _) { panic as "resolver must not run for disallowed host" },
      destination.default() |> destination.only_hosts(["other.test"]),
      error.DestinationRejected(destination.HostNotAllowed),
    ),
  ]
  list.each(cases, fn(row) {
    let #(port, listener) = listen()
    let c =
      config.default()
      |> config.with_destination(row.1)
      |> config.with_resolver(row.0)
    let assert Ok(client) = http_gun.start(c)
    let actual = http_gun.send(client, local_request(port, "localhost"))
    let seen = connected(listener)
    http_gun.stop(client)
    actual |> should.equal(Error(error.new(row.2, error.NotSent)))
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
  let settings =
    local_config()
    |> config.with_destination(
      destination.default()
      |> destination.allow_loopback
      |> destination.only_hosts(["LOCALHOST"]),
    )
    |> config.with_resolver(fn(_, _) {
      case increment(calls) {
        1 -> Ok([destination.Ipv4(127, 0, 0, 1)])
        _ -> Ok([destination.Ipv4(10, 0, 0, 1)])
      }
    })
  let assert Ok(client) = http_gun.start(settings)
  let req = local_request(server(), "localhost")
  let assert Ok(first) = http_gun.send(client, req)
  let assert Ok(second) = http_gun.send(client, req)
  response.get_header(first.response, "x-connection")
  |> should.equal(response.get_header(second.response, "x-connection"))
  count(calls) |> should.equal(1)
  http_gun.stop(client)
  // A new client/connection cannot reuse a formerly permitted answer.
  let assert Ok(next) = http_gun.start(settings)
  http_gun.send(next, req)
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Private))),
  )
  count(calls) |> should.equal(2)
  http_gun.stop(next)
}

pub fn literals_bypass_resolver_and_loopback_requires_opt_in_test() {
  let settings =
    local_config()
    |> config.with_resolver(fn(_, _) { panic as "literal must not resolve" })
  let assert Ok(client) = http_gun.start(settings)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn policy_validation_is_pure_test() {
  let c = config.default()
  config.validate(config.with_destination(
    c,
    destination.default() |> destination.only_hosts([""]),
  ))
  |> should.equal(Error(config.InvalidAllowedHost("")))
  config.validate(
    c
    |> config.with_destination(
      destination.default() |> destination.only_hosts([]),
    )
    |> config.with_resolver(fn(_, _) { panic as "validation is pure" }),
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
  let settings =
    local_config()
    |> config.with_trust(config.CustomCa("test/fixtures/ca.crt"))
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(127, 0, 0, 1)]) })
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
  |> should.equal(error.new(
    error.ConnectionFailed(error.CertificateRejected),
    error.NotSent,
  ))
  http_gun.stop(client)
}

pub fn ip_literal_tls_checks_ip_san_test() {
  let c = local_config()
  let assert Ok(client) =
    http_gun.start(config.with_trust(
      c,
      config.CustomCa("test/fixtures/ip_ca.crt"),
    ))
  let assert Ok(reply) =
    http_gun.send(
      client,
      local_request(tls_ip(), "127.0.0.1") |> request.set_scheme(http.Https),
    )
  reply.response.status |> should.equal(200)
  http_gun.stop(client)
  let assert Ok(client) =
    http_gun.start(config.with_trust(c, config.CustomCa("test/fixtures/ca.crt")))
  let assert Error(failure) =
    http_gun.send(
      client,
      local_request(tls_hostname(), "127.0.0.1")
        |> request.set_scheme(http.Https),
    )
  failure
  |> should.equal(error.new(
    error.ConnectionFailed(error.CertificateRejected),
    error.NotSent,
  ))
  http_gun.stop(client)
}

pub fn reserved_never_allowed_and_public_can_be_disabled_test() {
  list.each(
    [
      #(destination.Ipv4(100, 100, 100, 200), destination.Reserved),
      #(
        destination.Ipv6(0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254),
        destination.Reserved,
      ),
      #(destination.Ipv4(8, 8, 8, 8), destination.Public),
    ],
    fn(row) {
      let settings =
        config.default()
        |> config.with_destination(
          destination.loopback_only() |> destination.allow_private,
        )
        |> config.with_resolver(fn(_, _) { Ok([row.0]) })
      let #(port, listener) = listen()
      let assert Ok(client) = http_gun.start(settings)
      http_gun.send(client, local_request(port, "localhost"))
      |> should.equal(Error(rejected(destination.AddressRefused(row.1))))
      connected(listener) |> should.be_false
      http_gun.stop(client)
    },
  )
}

pub fn resolution_lifetime_cleanup_test() {
  list.each(
    ["cancel", "deadline", "caller_death", "shutdown", "client_death"],
    fn(mode) {
      let entered = process.new_subject()
      let ready = process.new_subject()
      let settings =
        local_config()
        |> config.with_request_timeout(
          config.Milliseconds(case mode {
            "deadline" -> 150
            _ -> 5000
          }),
        )
        |> config.with_resolver(fn(_, budget) {
          { budget > 0 } |> should.be_true
          process.send(entered, process.self())
          let forever: process.Subject(Nil) = process.new_subject()
          let _ = process.receive_forever(forever)
          Ok([destination.Ipv4(127, 0, 0, 1)])
        })
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
      cancellation.with_token(fn(token) {
        let caller =
          process.spawn_unlinked(fn() {
            process.send(
              result,
              http_gun.send(
                http_gun.with_cancellation(client, token),
                local_request(port, "localhost"),
              ),
            )
          })
        let assert Ok(resolver) = process.receive(entered, 1000)
        let monitor = process.monitor(resolver)
        case mode {
          "cancel" -> cancellation.cancel(token)
          "caller_death" -> process.kill(caller)
          "shutdown" -> http_gun.stop(client)
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
              "cancel" -> error.new(error.Cancelled, error.NotSent)
              "deadline" -> error.new(error.DeadlineExceeded, error.NotSent)
              "client_death" -> error.new(error.ClientClosed, error.MaybeSent)
              _ -> error.new(error.ClientClosed, error.NotSent)
            }
            failure |> should.equal(expected)
          }
        }
      })
      connected(listener) |> should.be_false
      http_gun.stop(client)
      process.kill(service)
    },
  )
}

pub fn slow_resolution_does_not_block_other_origins_test() {
  let entered = process.new_subject()
  let settings =
    local_config()
    |> config.with_resolver(fn(_, _) {
      process.send(entered, Nil)
      let forever: process.Subject(Nil) = process.new_subject()
      let _ = process.receive_forever(forever)
      Ok([])
    })
  let assert Ok(client) = http_gun.start(settings)
  let result = process.new_subject()
  cancellation.with_token(fn(token) {
    let _ =
      process.spawn_unlinked(fn() {
        process.send(
          result,
          http_gun.send(
            http_gun.with_cancellation(client, token),
            local_request(1, "localhost"),
          ),
        )
      })
    process.receive(entered, 1000) |> should.equal(Ok(Nil))
    let assert Ok(reply) =
      http_gun.send(client, local_request(server(), "127.0.0.1"))
    reply.response.status |> should.equal(200)
    cancellation.cancel(token)
    let assert Ok(Error(failure)) = process.receive(result, 1000)
    error.reason(failure) |> should.equal(error.Cancelled)
  })
  http_gun.stop(client)
}

pub fn throwing_resolver_is_typed_and_does_not_kill_pool_test() {
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_resolver(fn(_, _) { panic as "injected resolver failure" }),
    )
  http_gun.send(client, local_request(1, "localhost"))
  |> should.equal(Error(error.new(error.ResolutionFailed, error.NotSent)))
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.status |> should.equal(200)
  http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove_fixture(path: String) -> Nil

pub fn recording_enforces_destination_and_offline_modes_never_resolve_test() {
  let settings =
    config.default()
    |> config.with_resolver(fn(_, _) { panic as "offline cannot resolve" })
  let req = local_request(1, "127.0.0.1")
  let file = temp_path()
  let assert Ok(recorded) = cassette.record(settings, file, cassette.options())
  let failure = rejected(destination.AddressRefused(destination.Loopback))
  http_gun.send(recorded.client, req) |> should.equal(Error(failure))
  cassette.finish(recorded.recording, 2000) |> should.equal(Ok(file))
  http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(file, 10_000)
  let assert Ok(replay) = testing.playback(tape, settings)
  http_gun.send(replay, req |> request.set_path("/mismatch"))
  |> should.equal(Error(error.new(error.PlaybackMismatch(0), error.NotSent)))
  http_gun.send(replay, req) |> should.equal(Error(failure))
  http_gun.stop(replay)
  remove_fixture(file)
  let assert Ok(script) =
    testing.playback(
      testing.script([
        testing.exchange(
          req,
          testing.Respond(
            response.new(200) |> response.set_body([<<"offline":utf8>>]),
            testing.Finished([]),
          ),
        ),
      ]),
      settings,
    )
  let assert Ok(reply) = http_gun.send(script, req)
  reply.response.body |> should.equal(<<"offline":utf8>>)
  http_gun.stop(script)
}

// The three one-line setups.

pub fn allow_loopback_setup_admits_loopback_and_public_test() {
  let c = config.default() |> config.allow_loopback
  let policy = destination.default() |> destination.allow_loopback
  // The one-liner is exactly the public policy plus loopback.
  c |> should.equal(config.with_destination(config.default(), policy))
  destination.check(policy, "8.8.8.8", 443) |> should.equal(Ok(Nil))
  destination.check(policy, "example.com", 443) |> should.equal(Ok(Nil))
  destination.check(policy, "127.0.0.1", 80) |> should.equal(Ok(Nil))
  destination.check(policy, "10.0.0.1", 80)
  |> should.equal(Error(destination.AddressRefused(destination.Private)))
  let assert Ok(client) = http_gun.start(c)
  let port = server()
  let assert Ok(reply) = http_gun.send(client, local_request(port, "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let assert Ok(reply) = http_gun.send(client, local_request(port, "localhost"))
  reply.response.status |> should.equal(200)
  http_gun.stop(client)
  // Private and reserved resolutions stay refused without connecting.
  list.each(
    [
      #(destination.Ipv4(192, 168, 1, 1), destination.Private),
      #(destination.Ipv4(169, 254, 169, 254), destination.Reserved),
    ],
    fn(row) {
      let #(port, listener) = listen()
      let assert Ok(client) =
        http_gun.start(c |> config.with_resolver(fn(_, _) { Ok([row.0]) }))
      http_gun.send(client, local_request(port, "service.test"))
      |> should.equal(Error(rejected(destination.AddressRefused(row.1))))
      connected(listener) |> should.be_false
      http_gun.stop(client)
    },
  )
}

pub fn loopback_only_setup_refuses_public_test() {
  let c =
    config.default() |> config.with_destination(destination.loopback_only())
  let assert Ok(client) = http_gun.start(c)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let assert Ok(reply) =
    http_gun.send(client, local_request(server(), "localhost"))
  reply.response.status |> should.equal(200)
  // A public literal is refused before any connection.
  http_gun.send(client, local_request(443, "8.8.8.8"))
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Public))),
  )
  http_gun.stop(client)
  // A host name resolving to a public or private address is refused too.
  list.each(
    [
      #(destination.Ipv4(8, 8, 8, 8), destination.Public),
      #(destination.Ipv4(10, 1, 2, 3), destination.Private),
      #(
        destination.Ipv6(0x2606, 0x4700, 0, 0, 0, 0, 0, 0x1111),
        destination.Public,
      ),
    ],
    fn(row) {
      let #(port, listener) = listen()
      let assert Ok(client) =
        http_gun.start(c |> config.with_resolver(fn(_, _) { Ok([row.0]) }))
      http_gun.send(client, local_request(port, "service.test"))
      |> should.equal(Error(rejected(destination.AddressRefused(row.1))))
      connected(listener) |> should.be_false
      http_gun.stop(client)
    },
  )
}

pub fn pinned_local_server_setup_admits_exactly_one_server_test() {
  let port = server()
  let #(other, listener) = listen()
  let c =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
    )
  let assert Ok(client) = http_gun.start(c)
  let assert Ok(reply) = http_gun.send(client, local_request(port, "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  // Another port on the same host is refused.
  http_gun.send(client, local_request(other, "127.0.0.1"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  // The same port under another name is refused: the list names 127.0.0.1.
  http_gun.send(client, local_request(port, "localhost"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  connected(listener) |> should.be_false
  http_gun.stop(client)
}

// Host list entries.

pub fn host_port_entries_admit_one_port_test() {
  let port = server()
  let #(other, listener) = listen()
  let c =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["LocalHost:" <> int.to_string(port)]),
    )
  let assert Ok(client) = http_gun.start(c)
  // Entries compare without case.
  let assert Ok(reply) = http_gun.send(client, local_request(port, "localhost"))
  reply.response.status |> should.equal(200)
  let assert Ok(reply) = http_gun.send(client, local_request(port, "LOCALHOST"))
  reply.response.status |> should.equal(200)
  http_gun.send(client, local_request(other, "localhost"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  connected(listener) |> should.be_false
  http_gun.stop(client)
  // A bare host entry admits every port.
  let any_port =
    destination.loopback_only() |> destination.only_hosts(["localhost"])
  destination.check(any_port, "localhost", port) |> should.equal(Ok(Nil))
  destination.check(any_port, "localhost", other) |> should.equal(Ok(Nil))
  destination.check(any_port, "127.0.0.1", port)
  |> should.equal(Error(destination.HostNotAllowed))
  // Calling only_hosts again replaces the list.
  let replaced = any_port |> destination.only_hosts(["127.0.0.1"])
  destination.check(replaced, "localhost", port)
  |> should.equal(Error(destination.HostNotAllowed))
  destination.check(replaced, "127.0.0.1", port) |> should.equal(Ok(Nil))
}

pub fn bracketed_ipv6_entries_parse_with_and_without_port_test() {
  let pinned =
    destination.loopback_only() |> destination.only_hosts(["[::1]:8080"])
  destination.validate(pinned) |> should.equal(Ok(pinned))
  destination.check(pinned, "::1", 8080) |> should.equal(Ok(Nil))
  destination.check(pinned, "[::1]", 8080) |> should.equal(Ok(Nil))
  destination.check(pinned, "::1", 8081)
  |> should.equal(Error(destination.HostNotAllowed))
  destination.check(pinned, "127.0.0.1", 8080)
  |> should.equal(Error(destination.HostNotAllowed))
  let any_port =
    destination.loopback_only() |> destination.only_hosts(["[::1]"])
  destination.validate(any_port) |> should.equal(Ok(any_port))
  destination.check(any_port, "::1", 1) |> should.equal(Ok(Nil))
  destination.check(any_port, "::1", 65_535) |> should.equal(Ok(Nil))
  // A bare IPv6 literal has several colons and no port.
  let bare = destination.loopback_only() |> destination.only_hosts(["::1"])
  destination.validate(bare) |> should.equal(Ok(bare))
  destination.check(bare, "::1", 8080) |> should.equal(Ok(Nil))
  // Address classes still apply to a listed IPv6 host.
  let listed_public =
    destination.loopback_only()
    |> destination.only_hosts(["[2606:4700::1111]:443"])
  destination.check(listed_public, "2606:4700::1111", 443)
  |> should.equal(Error(destination.AddressRefused(destination.Public)))
  // Live: the pinned [::1]:port entry admits that IPv6 server only.
  let port = echo_authority(True)
  let assert Ok(client) =
    http_gun.start(
      config.default()
      |> config.with_destination(
        destination.loopback_only()
        |> destination.only_hosts(["[::1]:" <> int.to_string(port)]),
      ),
    )
  let assert Ok(req) = request.to("http://[::1]:" <> int.to_string(port))
  let assert Ok(reply) = http_gun.send(client, request.set_body(req, <<>>))
  reply.response.status |> should.equal(200)
  let assert Ok(req) = request.to("http://[::1]:" <> int.to_string(port + 1))
  http_gun.send(client, request.set_body(req, <<>>))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  http_gun.stop(client)
}

pub fn check_and_check_address_results_test() {
  let public = destination.default()
  let loopback = destination.loopback_only()
  let private = destination.default() |> destination.allow_private
  let listed =
    destination.loopback_only()
    |> destination.allow_private
    |> destination.only_hosts(["api.test", "127.0.0.1:8080", "10.0.0.1"])
  let refused = fn(class) { Error(destination.AddressRefused(class)) }
  [
    // A host name passes without resolving; its addresses are checked later.
    #(public, "example.com", 443, Ok(Nil)),
    #(loopback, "example.com", 443, Ok(Nil)),
    #(public, "93.184.216.34", 80, Ok(Nil)),
    #(public, "127.0.0.1", 80, refused(destination.Loopback)),
    #(public, "[::1]", 80, refused(destination.Loopback)),
    #(public, "10.0.0.1", 80, refused(destination.Private)),
    #(public, "169.254.169.254", 80, refused(destination.Reserved)),
    #(loopback, "127.0.0.1", 80, Ok(Nil)),
    #(loopback, "::1", 80, Ok(Nil)),
    #(loopback, "8.8.8.8", 53, refused(destination.Public)),
    #(loopback, "192.168.0.1", 80, refused(destination.Private)),
    #(private, "192.168.0.1", 80, Ok(Nil)),
    #(private, "fc00::1", 80, Ok(Nil)),
    #(private, "8.8.8.8", 53, Ok(Nil)),
    #(private, "127.0.0.1", 80, refused(destination.Loopback)),
    #(private, "100.100.100.200", 80, refused(destination.Reserved)),
    #(listed, "api.test", 1, Ok(Nil)),
    #(listed, "API.TEST", 1, Ok(Nil)),
    #(listed, "other.test", 1, Error(destination.HostNotAllowed)),
    #(listed, "127.0.0.1", 8080, Ok(Nil)),
    #(listed, "127.0.0.1", 8081, Error(destination.HostNotAllowed)),
    #(listed, "10.0.0.1", 9999, Ok(Nil)),
    // The host list is checked before the address class.
    #(listed, "8.8.8.8", 53, Error(destination.HostNotAllowed)),
  ]
  |> list.each(fn(row) {
    destination.check(row.0, row.1, row.2) |> should.equal(row.3)
  })
  let widest =
    destination.default()
    |> destination.allow_loopback
    |> destination.allow_private
  [
    #(public, destination.Ipv4(1, 1, 1, 1), Ok(Nil)),
    #(public, destination.Ipv4(127, 0, 0, 1), refused(destination.Loopback)),
    #(public, destination.Ipv4(172, 16, 0, 1), refused(destination.Private)),
    #(loopback, destination.Ipv6(0, 0, 0, 0, 0, 0, 0, 1), Ok(Nil)),
    #(loopback, destination.Ipv4(1, 1, 1, 1), refused(destination.Public)),
    #(private, destination.Ipv4(10, 9, 8, 7), Ok(Nil)),
    // Reserved is refused by every policy, including the widest.
    #(
      widest,
      destination.Ipv4(169, 254, 169, 254),
      refused(destination.Reserved),
    ),
    #(
      widest,
      destination.Ipv6(0xFD00, 0xEC2, 0, 0, 0, 0, 0, 0x254),
      refused(destination.Reserved),
    ),
    #(widest, destination.Ipv4(8, 8, 8, 8), Ok(Nil)),
    // check_address ignores the host list.
    #(listed, destination.Ipv4(127, 0, 0, 2), Ok(Nil)),
  ]
  |> list.each(fn(row) {
    destination.check_address(row.0, row.1) |> should.equal(row.2)
  })
  destination.parse_address("127.0.0.1")
  |> should.equal(Ok(destination.Ipv4(127, 0, 0, 1)))
  destination.parse_address("::1")
  |> should.equal(Ok(destination.Ipv6(0, 0, 0, 0, 0, 0, 0, 1)))
  destination.parse_address("localhost") |> should.equal(Error(Nil))
}

pub fn malformed_entries_fail_validation_and_start_test() {
  let malformed = [
    "", "api test", "api\ttest", "api/test", "api?x", "api#x", "user@api",
    "api:0", "api:65536", "api:-1", "api:http", "api:", ":8080", "[::1", "[]",
    "[]:80", "[::1]:", "[::1]:0", "[::1]x", "a:b:c",
  ]
  list.each(malformed, fn(entry) {
    let policy =
      destination.default() |> destination.only_hosts(["ok.test", entry])
    destination.validate(policy) |> should.equal(Error(entry))
    let c = config.default() |> config.with_destination(policy)
    config.validate(c) |> should.equal(Error(config.InvalidAllowedHost(entry)))
    http_gun.start(c)
    |> should.equal(
      Error(http_gun.InvalidConfig(config.InvalidAllowedHost(entry))),
    )
  })
  // The first malformed entry is reported.
  destination.default()
  |> destination.only_hosts(["a b", "api:0"])
  |> destination.validate
  |> should.equal(Error("a b"))
  // A malformed entry never matches a request.
  let policy = destination.default() |> destination.only_hosts(["api:0"])
  destination.check(policy, "api", 0)
  |> should.equal(Error(destination.HostNotAllowed))
  let valid =
    destination.default()
    |> destination.only_hosts([
      "api.test", "api.test:1", "api.test:65535", "[::1]", "[::1]:8080", "::1",
      "127.0.0.1:80",
    ])
  destination.validate(valid) |> should.equal(Ok(valid))
  // A malformed entry in a view policy never matches either.
  let assert Ok(client) = http_gun.start(local_config())
  let view =
    client
    |> http_gun.with_destination(
      destination.loopback_only() |> destination.only_hosts(["127.0.0.1:0"]),
    )
  http_gun.send(view, local_request(server(), "127.0.0.1"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  http_gun.stop(client)
}

// Per-call narrowing with http_gun.with_destination.

pub fn view_narrows_the_client_policy_test() {
  let port = server()
  let assert Ok(client) = http_gun.start(local_config())
  let #(sink, listener) = listen()
  let public_only = client |> http_gun.with_destination(destination.default())
  http_gun.send(public_only, local_request(sink, "127.0.0.1"))
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Loopback))),
  )
  connected(listener) |> should.be_false
  // A narrower view that still admits the server works.
  let pinned =
    client
    |> http_gun.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
    )
  let assert Ok(reply) = http_gun.send(pinned, local_request(port, "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let #(sink, listener) = listen()
  http_gun.send(pinned, local_request(sink, "127.0.0.1"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  connected(listener) |> should.be_false
  // Views stack: each added policy must also admit the request.
  let stacked = pinned |> http_gun.with_destination(destination.default())
  http_gun.send(stacked, local_request(port, "127.0.0.1"))
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Loopback))),
  )
  // The base client is unaffected by its views.
  let assert Ok(reply) = http_gun.send(client, local_request(port, "127.0.0.1"))
  reply.response.status |> should.equal(200)
  http_gun.stop(client)
}

pub fn narrower_view_cannot_reuse_a_wider_pooled_connection_test() {
  let port = server()
  let calls = counter()
  let assert Ok(client) =
    http_gun.start(
      local_config()
      |> config.with_resolver(fn(_, _) {
        let _ = increment(calls)
        Ok([destination.Ipv4(127, 0, 0, 1)])
      }),
    )
  let req = local_request(port, "localhost")
  // The wider client opens and pools a loopback connection for localhost.
  let assert Ok(first) = http_gun.send(client, req)
  let assert Ok(stats) = http_gun.stats(client)
  stats.connections |> should.equal(1)
  // A public-only view passes the host check (a name, not a literal), but the
  // pooled connection's checked addresses are loopback, so it is refused.
  let public_only = client |> http_gun.with_destination(destination.default())
  http_gun.send(public_only, req)
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Loopback))),
  )
  // A view whose host list excludes the origin is refused too.
  let elsewhere =
    client
    |> http_gun.with_destination(
      destination.loopback_only() |> destination.only_hosts(["other.test"]),
    )
  http_gun.send(elsewhere, req)
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  // A narrower view that admits the connection's addresses reuses it.
  let narrow =
    client
    |> http_gun.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["localhost:" <> int.to_string(port)]),
    )
  let assert Ok(second) = http_gun.send(narrow, req)
  response.get_header(second.response, "x-connection")
  |> should.equal(response.get_header(first.response, "x-connection"))
  count(calls) |> should.equal(1)
  http_gun.stop(client)
}

pub fn view_can_never_widen_the_client_policy_test() {
  let port = server()
  // A public-only client: a loopback view does not admit loopback.
  let assert Ok(client) = http_gun.start(config.default())
  let #(sink, listener) = listen()
  list.each(
    [
      destination.loopback_only(),
      destination.default() |> destination.allow_loopback,
      destination.loopback_only()
        |> destination.allow_private
        |> destination.only_hosts(["127.0.0.1:" <> int.to_string(sink)]),
    ],
    fn(policy) {
      let view = client |> http_gun.with_destination(policy)
      http_gun.send(view, local_request(sink, "127.0.0.1"))
      |> should.equal(
        Error(rejected(destination.AddressRefused(destination.Loopback))),
      )
    },
  )
  connected(listener) |> should.be_false
  http_gun.stop(client)
  // A client pinned to one server: a view admitting every port of the host
  // does not admit another port.
  let assert Ok(pinned) =
    http_gun.start(
      config.default()
      |> config.with_destination(
        destination.loopback_only()
        |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
      ),
    )
  let #(sink, listener) = listen()
  let wide =
    pinned
    |> http_gun.with_destination(
      destination.loopback_only() |> destination.only_hosts(["127.0.0.1"]),
    )
  http_gun.send(wide, local_request(sink, "127.0.0.1"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  connected(listener) |> should.be_false
  let assert Ok(reply) = http_gun.send(wide, local_request(port, "127.0.0.1"))
  reply.response.status |> should.equal(200)
  http_gun.stop(pinned)
  // A loopback-only client: a private view does not admit a private answer.
  let #(sink, listener) = listen()
  let assert Ok(local) =
    http_gun.start(
      config.default()
      |> config.with_destination(destination.loopback_only())
      |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) }),
    )
  let view =
    local
    |> http_gun.with_destination(
      destination.default() |> destination.allow_private,
    )
  http_gun.send(view, local_request(sink, "service.test"))
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Private))),
  )
  connected(listener) |> should.be_false
  http_gun.stop(local)
}

// A multi-tenant client admits the union of its tenants' destinations. With
// `require_view_destination`, a call that skips the tenant's view fails
// closed instead of reaching that union.
pub fn required_view_destination_refuses_a_bare_client_test() {
  let #(port, listener) = listen()
  let assert Ok(client) =
    local_config()
    |> config.require_view_destination
    |> config.with_request_timeout(config.Milliseconds(1000))
    |> http_gun.start
  let required = Error(error.new(error.ViewDestinationRequired, error.NotSent))
  let req = local_request(port, "127.0.0.1")
  http_gun.send(client, req) |> should.equal(required)
  // Other view settings do not count as a destination.
  http_gun.send(client |> http_gun.with_timeout(config.Milliseconds(500)), req)
  |> should.equal(required)
  let assert Error(failure) = http_gun.open(client, req)
  failure
  |> should.equal(error.new(error.ViewDestinationRequired, error.NotSent))
  error.kind(failure) |> should.equal(error.Refused)
  error.is_retryable(failure, idempotent: True) |> should.be_false
  http_gun.batch(client, [req, req], 2)
  |> should.equal(Ok([required, required]))
  // A public tenant's view refuses loopback; the local tenant's view admits it.
  http_gun.send(client |> http_gun.with_destination(destination.default()), req)
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Loopback))),
  )
  connected(listener) |> should.be_false
  let local = client |> http_gun.with_destination(destination.loopback_only())
  let assert Ok(reply) =
    http_gun.send(local, local_request(server(), "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn required_view_destination_never_widens_the_client_policy_test() {
  let port = server()
  let pinned = "127.0.0.1:" <> int.to_string(port)
  let #(other, listener) = listen()
  let assert Ok(client) =
    config.default()
    |> config.with_destination(
      destination.loopback_only() |> destination.only_hosts([pinned]),
    )
    |> config.require_view_destination
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) })
    |> http_gun.start
  let wide =
    destination.default()
    |> destination.allow_loopback
    |> destination.allow_private
  let view = client |> http_gun.with_destination(wide)
  // The client's host list still applies to a view without one.
  http_gun.send(view, local_request(other, "127.0.0.1"))
  |> should.equal(Error(rejected(destination.HostNotAllowed)))
  connected(listener) |> should.be_false
  // The client's address classes still apply: private stays refused.
  let assert Ok(client_private) =
    config.default()
    |> config.allow_loopback
    |> config.require_view_destination
    |> config.with_resolver(fn(_, _) { Ok([destination.Ipv4(10, 0, 0, 7)]) })
    |> http_gun.start
  http_gun.send(
    client_private |> http_gun.with_destination(wide),
    local_request(server(), "localhost"),
  )
  |> should.equal(
    Error(rejected(destination.AddressRefused(destination.Private))),
  )
  http_gun.stop(client_private)
  // Within the client's bound, the wide view is admitted.
  let assert Ok(reply) = http_gun.send(view, local_request(port, "127.0.0.1"))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  http_gun.stop(client)
}

pub fn required_view_destination_applies_to_playback_test() {
  let req = local_request(80, "127.0.0.1")
  let exchange =
    testing.exchange(
      req,
      testing.Respond(
        response.new(204) |> response.set_body([]),
        testing.Finished([]),
      ),
    )
  let assert Ok(client) =
    testing.playback(
      testing.script([exchange]),
      local_config() |> config.require_view_destination,
    )
  http_gun.send(client, req)
  |> should.equal(
    Error(error.new(error.ViewDestinationRequired, error.NotSent)),
  )
  // The refused call left the scripted exchange in place.
  let assert Ok(reply) =
    http_gun.send(
      client |> http_gun.with_destination(destination.loopback_only()),
      req,
    )
  reply.response.status |> should.equal(204)
  http_gun.stop(client)
}
