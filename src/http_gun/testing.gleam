/// Explicit, strictly ordered offline sessions. No network fallback.
import gleam/list
import gleam/result
import http_gun
import http_gun/config
import http_gun/error
import http_gun/fixture
import http_gun/internal/pool

pub fn start(
  settings: config.Config,
  exchanges: List(fixture.Exchange),
) -> Result(http_gun.Client, error.Failure) {
  use Nil <- result.try(
    fixture.validate(exchanges)
    |> result.map_error(fn(_) {
      error.Failure(error.FixtureCorrupt, error.NotSubmitted)
    }),
  )
  let size =
    list.fold(exchanges, 0, fn(total, exchange) {
      total + fixture.size(exchange)
    })
  case size <= 16_777_216 {
    False ->
      Error(error.Failure(
        error.LimitExceeded(error.FixtureBytes, 16_777_216, size),
        error.NotSubmitted,
      ))
    True ->
      pool.start_mode(settings, pool.Playback(exchanges, 0))
      |> result.map(fn(started) { started.data })
      |> result.map_error(fn(_) {
        error.Failure(
          error.InvalidConfig("invalid script configuration"),
          error.NotSubmitted,
        )
      })
  }
}
