import gleam/http/request
import gleam/http/response
import gleam/io
import http_gun
import http_gun/config
import http_gun/deadline
import http_gun/fixture
import http_gun/testing
import http_gun_async/feed_job

// Two independent jobs, explicitly bounded by the application's two slots.
// Startup may instead supply a shared live, recording or playback Client.
pub fn main() -> Nil {
  let req = request.new() |> request.set_body(<<>>)
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.new(200) |> response.set_body([<<"feed bytes":utf8>>]),
        fixture.Complete([]),
      ),
    )
  let assert Ok(client) = testing.start(config.default(), [exchange, exchange])
  let assert Ok(budget) = deadline.after(5000)
  let assert Ok(first) =
    feed_job.start(client, req, budget, fn(_) { Ok(feed_job.Continue) })
  let assert Ok(second) =
    feed_job.start(client, req, budget, fn(_) { Ok(feed_job.Stop) })
  let assert Ok(feed_job.Eof(10, [])) = feed_job.await(first, 1000)
  let assert Ok(feed_job.Early(10)) = feed_job.await(second, 1000)
  let assert Ok(Nil) = http_gun.stop(client)
  io.println("Two application-owned jobs completed on one shared client.")
}
