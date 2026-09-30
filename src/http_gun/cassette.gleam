/// Explicit disk playback. Loading never opens a network connection.
import gleam/bit_array
import gleam/list
import gleam/result
import gleam/string
import http_gun
import http_gun/config
import http_gun/error.{type Failure, Failure, NotSubmitted}
import http_gun/fixture
import http_gun/internal/codec
import http_gun/internal/file
import http_gun/internal/pool
import http_gun/recording
import http_gun/testing

pub opaque type Cassette {
  Cassette(exchanges: List(fixture.Exchange))
}

pub fn new(exchanges: List(fixture.Exchange)) -> Result(Cassette, Failure) {
  use Nil <- result.try(
    fixture.validate(exchanges)
    |> result.map_error(fn(_) { Failure(error.FixtureCorrupt, NotSubmitted) }),
  )
  case
    list.fold(exchanges, 0, fn(total, item) { total + fixture.size(item) })
    <= 16_777_216
  {
    True -> Ok(Cassette(exchanges))
    False ->
      Error(Failure(error.LimitExceeded("fixture", 16_777_216), NotSubmitted))
  }
}

pub fn encode(cassette: Cassette) -> String {
  codec.encode(cassette.exchanges)
}

pub fn parse(text: String, max_bytes: Int) -> Result(Cassette, Failure) {
  case string.byte_size(text) > max_bytes {
    True ->
      Error(Failure(error.LimitExceeded("fixture", max_bytes), NotSubmitted))
    False -> {
      use exchanges <- result.try(
        codec.parse(text)
        |> result.map_error(fn(reason) { Failure(reason, NotSubmitted) }),
      )
      new(exchanges)
    }
  }
}

pub fn load(path: String, max_bytes: Int) -> Result(Cassette, Failure) {
  use bytes <- result.try(
    file.read(path, max_bytes)
    |> result.map_error(fn(problem) {
      Failure(
        case problem {
          file.Missing -> error.FixtureMissing
          file.TooLarge -> error.LimitExceeded("fixture", max_bytes)
          _ -> error.FixtureCorrupt
        },
        NotSubmitted,
      )
    }),
  )
  use text <- result.try(
    bit_array.to_string(bytes)
    |> result.map_error(fn(_) { Failure(error.FixtureCorrupt, NotSubmitted) }),
  )
  parse(text, max_bytes)
}

pub fn playback(
  cassette: Cassette,
  settings: config.Config,
) -> Result(http_gun.Client, Failure) {
  testing.start(settings, cassette.exchanges)
}

pub type Recorded {
  Recorded(client: http_gun.Client, recording: recording.Recording)
}

pub type StartRecordingError {
  ClientFailure(Failure)
  CaptureFailure(recording.CaptureError)
}

pub fn record(
  settings: config.Config,
  destination: String,
  options: recording.Options,
) -> Result(Recorded, StartRecordingError) {
  use _ <- result.try(
    config.validate(settings)
    |> result.map_error(fn(message) {
      ClientFailure(Failure(error.InvalidConfig(message), NotSubmitted))
    }),
  )
  use recording <- result.try(
    recording.start(destination, options) |> result.map_error(CaptureFailure),
  )
  use started <- result.try(
    pool.start_mode(settings, pool.Record(recording))
    |> result.map_error(fn(_) {
      ClientFailure(Failure(error.ClientClosed, NotSubmitted))
    }),
  )
  recording.attach_client(recording, started.pid)
  Ok(Recorded(started.data, recording))
}

pub fn finish(
  recording: recording.Recording,
) -> Result(String, recording.FinishError) {
  recording.finish(recording)
}
