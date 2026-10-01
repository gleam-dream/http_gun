//// Run only by dev/async-consumer with token startup failing in its private copy.

import gleam/http/request
import gleam/int
import gleam/io
import http_gun
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/error
import http_gun_async/feed_job

type AppError {
  Startup(error.Failure)
}

@external(erlang, "http_gun_async_test_ffi", "mailbox_size")
fn mailbox_size() -> Int

pub fn main() -> Nil {
  let failure = error.Failure(error.ClientClosed, error.NotSubmitted)
  let mapped =
    cancellation.try_with_token(Startup, fn(_) {
      panic as "callback must not run after token startup fails"
    })
  let assert True = mapped == Error(Startup(failure))
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(budget) = deadline.after(5000)
  let before = mailbox_size()
  int.range(0, 64, Nil, fn(_, _) {
    let outcome =
      feed_job.start(
        client,
        request.new() |> request.set_body(<<>>),
        budget,
        fn(_) { panic as "HTTP must not open after token startup fails" },
      )
    let assert True = outcome == Error(feed_job.Http(failure))
    Nil
  })
  let assert True = mailbox_size() == before
  let assert Ok(stats) = http_gun.snapshot(client)
  let assert 0 = stats.connections
  let assert 0 = stats.bodies
  let assert 0 = stats.waiting
  let _ = http_gun.stop(client)
  io.println(
    "PASS token startup maps Failure; callback skipped; 64 failed job starts leave no completion messages",
  )
}
