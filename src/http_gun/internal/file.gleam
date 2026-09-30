import file_streams/file_open_mode.{
  type FileOpenMode, Append, Exclusive, Raw, Read, Write,
}
import file_streams/file_stream
import file_streams/file_stream_error
import gleam/bit_array
import gleam/result
import http_gun/internal/bridge
import simplifile

pub type FileError {
  Missing
  Exists
  Denied
  TooLarge
  IoError
}

pub fn read(path: String, limit: Int) -> Result(BitArray, FileError) {
  case limit < 0 {
    True -> Error(TooLarge)
    False -> {
      // Explicit modes avoid the convenience helper's read-ahead buffer.
      use stream <- with_file(path, [Read, Raw])
      case file_stream.read_bytes(stream, limit + 1) {
        Ok(bytes) ->
          case bit_array.byte_size(bytes) <= limit {
            True -> Ok(bytes)
            False -> Error(TooLarge)
          }
        Error(file_stream_error.Eof) -> Ok(<<>>)
        Error(problem) -> Error(stream_error(problem))
      }
    }
  }
}

pub fn write_new(path: String, bytes: BitArray) -> Result(Nil, FileError) {
  use stream <- with_file(path, [Write, Exclusive, Raw])
  file_stream.write_bytes(stream, bytes) |> result.map_error(stream_error)
}

pub fn append(path: String, bytes: BitArray) -> Result(Nil, FileError) {
  use stream <- with_file(path, [Append, Raw])
  file_stream.write_bytes(stream, bytes) |> result.map_error(stream_error)
}

fn with_file(
  path: String,
  modes: List(FileOpenMode),
  run: fn(file_stream.FileStream) -> Result(value, FileError),
) -> Result(value, FileError) {
  use stream <- result.try(
    file_stream.open(path, modes) |> result.map_error(stream_error),
  )
  bridge.on_exception(
    fn() {
      let outcome = run(stream)
      let closed = file_stream.close(stream) |> result.map_error(stream_error)
      use value <- result.try(outcome)
      use Nil <- result.try(closed)
      Ok(value)
    },
    fn() {
      let _ = file_stream.close(stream)
      Nil
    },
  )
}

pub fn directory(destination: String) -> Result(String, FileError) {
  let path = directory_name(destination)
  use Nil <- result.try(
    simplifile.create_directory(path) |> result.map_error(path_error),
  )
  case simplifile.set_permissions_octal(path, 0o700) {
    Ok(Nil) -> Ok(path)
    Error(problem) -> {
      remove_directory(path)
      Error(path_error(problem))
    }
  }
}

pub fn publish(
  source: String,
  destination: String,
  replace: Bool,
) -> Result(Nil, FileError) {
  case replace {
    True -> simplifile.rename(source, destination)
    False -> simplifile.create_link(source, destination)
  }
  |> result.map_error(path_error)
}

pub fn remove(path: String) -> Nil {
  let _ = simplifile.delete_file(path)
  Nil
}

fn stream_error(problem: file_stream_error.FileStreamError) -> FileError {
  case problem {
    file_stream_error.Enoent -> Missing
    file_stream_error.Eexist -> Exists
    file_stream_error.Eacces -> Denied
    _ -> IoError
  }
}

fn path_error(problem: simplifile.FileError) -> FileError {
  case problem {
    simplifile.Enoent -> Missing
    simplifile.Eexist -> Exists
    simplifile.Eacces -> Denied
    _ -> IoError
  }
}

@external(erlang, "http_gun_file_ffi", "directory_name")
fn directory_name(destination: String) -> String

// simplifile.delete is recursive; cleanup must only remove an empty directory.
@external(erlang, "http_gun_file_ffi", "remove_directory")
pub fn remove_directory(path: String) -> Nil
