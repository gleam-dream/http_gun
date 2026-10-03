//// Run only by dev/async-consumer with the client process's start failing in
//// its private HTTP Gun copy.

import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/io
import http_gun
import http_gun/cassette
import http_gun/config
import http_gun/error
import http_gun/testing
import http_gun_async/feed_job

@external(erlang, "http_gun_async_test_ffi", "mailbox_size")
fn mailbox_size() -> Int

pub fn main() -> Nil {
  let settings = config.default()
  // Configuration is checked before any process starts, so a configuration
  // error is still reported as such.
  let assert Error(http_gun.InvalidConfig(config.OutOfRange(
    config.MaxConnections,
    0,
  ))) = http_gun.start(settings |> config.with_max_connections(0))
  // Every way of starting a client maps the failed start to StartFailed.
  let assert Error(http_gun.StartFailed) = http_gun.start(settings)
  let assert Error(http_gun.StartFailed) =
    testing.playback(testing.script([]), settings)
  let assert Error(cassette.ClientFailed(http_gun.StartFailed)) =
    cassette.record(
      settings,
      "build/startup-failure.json",
      cassette.options() |> cassette.replace_existing,
    )
  let assert Error(cassette.Missing) =
    cassette.load("build/startup-failure.json", 1000)
  // The application's supervised client fails its supervisor's start. The
  // caller traps the supervisor's exit so the failure stays a value.
  process.trap_exits(True)
  let name = process.new_name("http_gun_async_startup")
  let assert Error(_) = feed_job.supervise(settings, name)
  let assert Error(Nil) = process.named(name)
  // A handle to a client that never started fails before sending anything.
  let assert Error(failure) =
    http_gun.send(http_gun.named(name), request.new() |> request.set_body(<<>>))
  let assert error.ClientClosed = error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  let assert True = error.is_retryable(failure, idempotent: False)
  process.flush_messages()
  let before = mailbox_size()
  int.range(0, 64, Nil, fn(_, _) {
    let assert Error(http_gun.StartFailed) = http_gun.start(settings)
    Nil
  })
  let assert True = mailbox_size() == before
  io.println(
    "PASS client start failure maps to StartFailed for start, playback, record and supervised; 64 failed starts leave no messages",
  )
}
