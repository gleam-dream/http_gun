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

/// Validate ordered observations within the fixed 16 MiB estimated data budget.
/// No network or filesystem operations are performed.
pub fn new(exchanges: List(fixture.Exchange)) -> Result(Cassette, Failure) {
  use Nil <- result.try(
    fixture.validate(exchanges)
    |> result.map_error(fn(_) { Failure(error.FixtureCorrupt, NotSubmitted) }),
  )
  let size =
    list.fold(exchanges, 0, fn(total, exchange) {
      total + fixture.size(exchange)
    })
  case size <= 16_777_216 {
    True -> Ok(Cassette(exchanges))
    False ->
      Error(Failure(
        error.LimitExceeded(error.FixtureBytes, 16_777_216, size),
        NotSubmitted,
      ))
  }
}

/// Encode the current fixture schema with exact byte lengths and base64 bodies.
pub fn encode(cassette: Cassette) -> String {
  codec.encode(cassette.exchanges)
}

/// Decode the single current fixture schema within max_bytes.
/// Negative budgets are invalid configuration. Corrupt or unsupported fixtures
/// return errors; there is no legacy decoder or fallback mode.
pub fn parse(text: String, max_bytes: Int) -> Result(Cassette, Failure) {
  use Nil <- result.try(validate_byte_limit(max_bytes))
  case string.byte_size(text) > max_bytes {
    True ->
      Error(Failure(
        error.LimitExceeded(
          error.FixtureBytes,
          max_bytes,
          string.byte_size(text),
        ),
        NotSubmitted,
      ))
    False -> {
      use exchanges <- result.try(
        codec.parse(text)
        |> result.map_error(fn(reason) { Failure(reason, NotSubmitted) }),
      )
      new(exchanges)
    }
  }
}

/// Read at most max_bytes plus one byte before decoding. Never opens a network
/// connection. Missing files, IO failures, corrupt data and unknown versions differ.
pub fn load(path: String, max_bytes: Int) -> Result(Cassette, Failure) {
  use Nil <- result.try(validate_byte_limit(max_bytes))
  use bytes <- result.try(
    file.read(path, max_bytes)
    |> result.map_error(fn(problem) {
      Failure(
        case problem {
          file.Io(_, error.FileMissing) -> error.FixtureMissing
          file.TooLarge ->
            error.LimitExceeded(error.FixtureBytes, max_bytes, max_bytes + 1)
          file.Io(operation, cause) -> error.FixtureIo(operation, cause)
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

/// Start a strictly offline client. Matching consumes only the next exchange;
/// mismatches leave it available. Concurrent callers take client admission order.
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

/// Start a live client and an incremental recorder with explicit publication policy.
/// Capture failures are separate from HTTP outcomes. Bodies and queries stay exact
/// and can contain secrets. Finalize the recording and stop the client separately.
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

/// Attempt immediate finalization; Busy means HTTP or writer work is unfinished.
/// Use recording.finish_wait to seal new work and await publication with a time limit.
pub fn finish(
  recording: recording.Recording,
) -> Result(String, recording.FinishError) {
  recording.finish(recording)
}

fn validate_byte_limit(max_bytes: Int) -> Result(Nil, Failure) {
  case max_bytes < 0 {
    True ->
      Error(Failure(
        error.InvalidConfig("fixture byte limit must not be negative"),
        NotSubmitted,
      ))
    False -> Ok(Nil)
  }
}
