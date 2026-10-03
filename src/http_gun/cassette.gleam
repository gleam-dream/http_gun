//// Loads, saves and records HTTP exchanges as cassette files.
////
//// Record once against a live server, then replay offline:
////
//// ```gleam
//// // Recording, for example behind a flag in a test helper.
//// let assert Ok(cassette.Recorded(client:, recording:)) =
////   cassette.record(settings, "test/cassettes/orders.json", cassette.options())
//// let _ = http_gun.send(client, req)
//// let assert Ok(_path) = cassette.finish(recording, 5000)
//// http_gun.stop(client)
////
//// // Playback.
//// let assert Ok(script) = cassette.load("test/cassettes/orders.json", 1_048_576)
//// let assert Ok(client) = testing.playback(script, settings)
//// ```
////
//// A cassette is readable JSON (`"http_gun": 2`): a body or chunk that is
//// valid UTF-8 is stored as `{"text": ..}`, anything else as
//// `{"base64": ..}`. There is one schema; a file of another version fails
//// with `UnsupportedVersion`.
////
//// What a cassette stores follows the configuration's redaction
//// (`config.with_redaction`): the credential headers by default, plus any
//// headers, query parameters and body rewriting you add. Bodies and queries
//// are otherwise stored exactly and can contain secrets.
////
//// A recording writes each exchange as it completes, within a byte budget,
//// and publishes the file atomically when `finish` succeeds. Capture
//// failures are separate from HTTP outcomes: the live client keeps working.

import gleam/bit_array
import gleam/int
import gleam/result
import gleam/string
import http_gun
import http_gun/config
import http_gun/internal/codec
import http_gun/internal/file
import http_gun/internal/pool
import http_gun/internal/recorder
import http_gun/internal/script
import http_gun/redaction
import http_gun/testing

/// A filesystem operation that failed.
pub type FileOperation {
  OpenFile
  ReadFile
  WriteFile
  CloseFile
  CreateDirectory
  SetPermissions
  PublishFile
}

/// Why a filesystem operation failed.
pub type FileCause {
  FileMissing
  AlreadyExists
  PermissionDenied
  NoSpace
  ReadOnlyFilesystem
  NotDirectory
  IsDirectory
  CrossFilesystem
  UnknownIoFailure
}

/// Why a cassette could not be loaded or parsed.
pub type CassetteError {
  Missing
  Io(operation: FileOperation, cause: FileCause)
  /// Not UTF-8 JSON in the cassette schema.
  Corrupt
  UnsupportedVersion(version: Int)
  TooLarge(limit: Int, observed: Int)
}

/// A started recording: a live client and the capture to finish.
pub type Recorded {
  Recorded(client: http_gun.Client, recording: Recording)
}

/// A capture in progress. Finish or abort it; stop the client separately.
pub type Recording =
  recorder.Recording

/// How a recording publishes its file.
pub opaque type RecordOptions {
  RecordOptions(max_bytes: Int, replace: Bool)
}

/// Why a recording could not start or failed while capturing.
pub type RecordError {
  ClientFailed(http_gun.StartError)
  /// The capture exceeded its byte budget or 10,000 exchanges, or the budget
  /// is outside 1 byte to 16 MiB.
  CaptureLimit
  IoFailure(operation: FileOperation, cause: FileCause)
  /// The destination exists and `replace_existing` was not set.
  DestinationExists
  /// The recording is finishing or finished.
  RecordingClosed
  /// The recording's owner exited, or a writer crashed.
  Interrupted
}

/// Why `finish` returned without a published file.
pub type FinishError {
  /// Requests are still in flight; only an immediate finish returns this.
  Busy
  /// The wait ended; finishing continues and a later call sees the outcome.
  WaitTimeout
  CaptureFailed(RecordError)
}

/// Capture at most 16 MiB of encoded data and refuse to replace an existing
/// file.
pub fn options() -> RecordOptions {
  RecordOptions(max_bytes: 16_777_216, replace: False)
}

/// The capture's byte budget, 1 byte to 16 MiB.
pub fn with_max_bytes(options: RecordOptions, bytes: Int) -> RecordOptions {
  RecordOptions(..options, max_bytes: bytes)
}

/// Replace the destination file if it exists.
pub fn replace_existing(options: RecordOptions) -> RecordOptions {
  RecordOptions(..options, replace: True)
}

/// Encode a script as a cassette. Credential headers are never written.
pub fn encode(script: testing.Script) -> String {
  codec.encode(testing.exchanges(script), redaction.default())
}

/// Parse a cassette of at most `max_bytes`.
pub fn parse(
  text: String,
  max_bytes: Int,
) -> Result(testing.Script, CassetteError) {
  let size = string.byte_size(text)
  case size > max_bytes {
    True -> Error(TooLarge(int.max(0, max_bytes), size))
    False ->
      codec.parse(text)
      |> result.map(fn(exchanges) { script.Script(exchanges, script.exact) })
      |> result.map_error(fn(problem) {
        case problem {
          codec.Corrupt -> Corrupt
          codec.UnsupportedVersion(version) -> UnsupportedVersion(version)
        }
      })
  }
}

/// Read and parse a cassette file of at most `max_bytes`, reading no more
/// than `max_bytes` plus one byte. Never opens a network connection.
pub fn load(
  path: String,
  max_bytes: Int,
) -> Result(testing.Script, CassetteError) {
  let max_bytes = int.max(0, max_bytes)
  use bytes <- result.try(
    file.read(path, max_bytes)
    |> result.map_error(fn(problem) {
      case problem {
        file.Io(_, file.Missing) -> Missing
        file.TooLarge -> TooLarge(max_bytes, max_bytes + 1)
        file.Io(operation, cause) ->
          Io(file_operation(operation), file_cause(cause))
      }
    }),
  )
  use text <- result.try(
    bit_array.to_string(bytes) |> result.replace_error(Corrupt),
  )
  parse(text, max_bytes)
}

/// Start a live client that records every exchange to `path`. Finish the
/// recording with `finish` and stop the client separately.
pub fn record(
  settings: config.Config,
  path: String,
  options: RecordOptions,
) -> Result(Recorded, RecordError) {
  use settings <- result.try(
    config.validate(settings)
    |> result.map_error(fn(problem) {
      ClientFailed(http_gun.InvalidConfig(problem))
    }),
  )
  use recording <- result.try(
    recorder.start(
      path,
      recorder.Options(
        max_bytes: options.max_bytes,
        replacement: case options.replace {
          True -> recorder.ReplaceExisting
          False -> recorder.RefuseExisting
        },
        redaction: settings.redaction,
      ),
    )
    |> result.map_error(record_error),
  )
  use started <- result.try(case pool.start(settings, pool.Record(recording)) {
    Ok(started) -> Ok(started)
    Error(_) -> {
      recorder.discard(recording)
      Error(ClientFailed(http_gun.StartFailed))
    }
  })
  recorder.attach_client(recording, started.pid)
  Ok(Recorded(started.data, recording))
}

/// Publish the recording. Zero or less finishes now if nothing is in flight
/// and returns `Busy` otherwise. A positive wait refuses new requests, waits
/// up to `wait_ms` for the requests in flight, then publishes. Once finished
/// or failed, every later call returns the same outcome.
pub fn finish(
  recording: Recording,
  wait_ms: Int,
) -> Result(String, FinishError) {
  case wait_ms > 0 {
    True -> recorder.finish_wait(recording, wait_ms)
    False -> recorder.finish(recording)
  }
  |> result.map_error(fn(problem) {
    case problem {
      recorder.Busy -> Busy
      recorder.WaitTimeout -> WaitTimeout
      recorder.CaptureFailed(cause) -> CaptureFailed(record_error(cause))
    }
  })
}

/// Abandon the capture; the live client keeps working. A published file is
/// not removed.
pub fn abort(recording: Recording) -> Result(Nil, RecordError) {
  recorder.abort(recording) |> result.map_error(record_error)
}

pub fn describe_error(problem: CassetteError) -> String {
  case problem {
    Missing -> "cassette missing"
    Io(operation, cause) -> describe_io(operation, cause)
    Corrupt -> "cassette corrupt"
    UnsupportedVersion(version) ->
      "cassette version " <> int.to_string(version) <> " unsupported"
    TooLarge(limit, observed) ->
      "cassette of "
      <> int.to_string(observed)
      <> " bytes exceeds its limit of "
      <> int.to_string(limit)
  }
}

pub fn describe_record_error(problem: RecordError) -> String {
  case problem {
    ClientFailed(start) -> http_gun.describe_start_error(start)
    CaptureLimit -> "recording byte or exchange limit reached"
    IoFailure(operation, cause) -> describe_io(operation, cause)
    DestinationExists -> "recording destination exists"
    RecordingClosed -> "recording closed"
    Interrupted -> "recording interrupted"
  }
}

pub fn describe_finish_error(problem: FinishError) -> String {
  case problem {
    Busy -> "recording busy"
    WaitTimeout -> "recording did not finish in time"
    CaptureFailed(cause) -> describe_record_error(cause)
  }
}

fn describe_io(operation: FileOperation, cause: FileCause) -> String {
  let operation = case operation {
    OpenFile -> "opening file"
    ReadFile -> "reading file"
    WriteFile -> "writing file"
    CloseFile -> "closing file"
    CreateDirectory -> "creating directory"
    SetPermissions -> "setting permissions"
    PublishFile -> "publishing file"
  }
  operation
  <> " failed: "
  <> case cause {
    FileMissing -> "file missing"
    AlreadyExists -> "already exists"
    PermissionDenied -> "permission denied"
    NoSpace -> "no space available"
    ReadOnlyFilesystem -> "read-only filesystem"
    NotDirectory -> "not a directory"
    IsDirectory -> "is a directory"
    CrossFilesystem -> "cross-filesystem operation"
    UnknownIoFailure -> "cause unavailable"
  }
}

fn record_error(problem: recorder.CaptureError) -> RecordError {
  case problem {
    recorder.CaptureLimit -> CaptureLimit
    recorder.IoFailure(operation, cause) ->
      IoFailure(file_operation(operation), file_cause(cause))
    recorder.DestinationExists -> DestinationExists
    recorder.SessionClosed -> RecordingClosed
    recorder.Interrupted -> Interrupted
  }
}

fn file_operation(operation: file.Operation) -> FileOperation {
  case operation {
    file.OpenFile -> OpenFile
    file.ReadFile -> ReadFile
    file.WriteFile -> WriteFile
    file.CloseFile -> CloseFile
    file.CreateDirectory -> CreateDirectory
    file.SetPermissions -> SetPermissions
    file.Publish -> PublishFile
  }
}

fn file_cause(cause: file.Cause) -> FileCause {
  case cause {
    file.Missing -> FileMissing
    file.AlreadyExists -> AlreadyExists
    file.PermissionDenied -> PermissionDenied
    file.NoSpace -> NoSpace
    file.ReadOnlyFilesystem -> ReadOnlyFilesystem
    file.NotDirectory -> NotDirectory
    file.IsDirectory -> IsDirectory
    file.CrossFilesystem -> CrossFilesystem
    file.UnknownIo -> UnknownIoFailure
  }
}
