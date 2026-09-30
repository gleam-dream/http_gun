import file_streams/file_open_mode.{
  type FileOpenMode, Append, Exclusive, Raw, Read, Write,
}
import file_streams/file_stream
import file_streams/file_stream_error
import gleam/bit_array
import gleam/result
import http_gun/error
import http_gun/internal/bridge
import simplifile

pub type FileError {
  Io(error.FileOperation, error.FileCause)
  TooLarge
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
        Error(problem) -> Error(stream_error(error.ReadFile, problem))
      }
    }
  }
}

pub fn write_new(path: String, bytes: BitArray) -> Result(Nil, FileError) {
  use stream <- with_file(path, [Write, Exclusive, Raw])
  file_stream.write_bytes(stream, bytes)
  |> result.map_error(stream_error(error.WriteFile, _))
}

pub fn append(path: String, bytes: BitArray) -> Result(Nil, FileError) {
  use stream <- with_file(path, [Append, Raw])
  file_stream.write_bytes(stream, bytes)
  |> result.map_error(stream_error(error.WriteFile, _))
}

fn with_file(
  path: String,
  modes: List(FileOpenMode),
  run: fn(file_stream.FileStream) -> Result(value, FileError),
) -> Result(value, FileError) {
  use stream <- result.try(
    file_stream.open(path, modes)
    |> result.map_error(stream_error(error.OpenFile, _)),
  )
  bridge.on_exception(
    fn() {
      let outcome = run(stream)
      let closed =
        file_stream.close(stream)
        |> result.map_error(stream_error(error.CloseFile, _))
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
    simplifile.create_directory(path)
    |> result.map_error(path_error(error.CreateDirectory, _)),
  )
  case simplifile.set_permissions_octal(path, 0o700) {
    Ok(Nil) -> Ok(path)
    Error(problem) -> {
      remove_directory(path)
      Error(path_error(error.SetPermissions, problem))
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
  |> result.map_error(path_error(error.PublishFixture, _))
}

pub fn remove(path: String) -> Nil {
  let _ = simplifile.delete_file(path)
  Nil
}

fn stream_error(
  operation: error.FileOperation,
  problem: file_stream_error.FileStreamError,
) -> FileError {
  Io(operation, case problem {
    file_stream_error.Enoent -> error.FileMissing
    file_stream_error.Eexist -> error.AlreadyExists
    file_stream_error.Eacces -> error.PermissionDenied
    file_stream_error.Eperm -> error.PermissionDenied
    file_stream_error.Enospc -> error.NoSpace
    file_stream_error.Erofs -> error.ReadOnlyFilesystem
    file_stream_error.Enotdir -> error.NotDirectory
    file_stream_error.Eisdir -> error.IsDirectory
    file_stream_error.Exdev -> error.CrossFilesystem
    _ -> error.UnknownIoFailure
  })
}

fn path_error(
  operation: error.FileOperation,
  problem: simplifile.FileError,
) -> FileError {
  Io(operation, case problem {
    simplifile.Enoent -> error.FileMissing
    simplifile.Eexist -> error.AlreadyExists
    simplifile.Eacces -> error.PermissionDenied
    simplifile.Eperm -> error.PermissionDenied
    simplifile.Enospc -> error.NoSpace
    simplifile.Erofs -> error.ReadOnlyFilesystem
    simplifile.Enotdir -> error.NotDirectory
    simplifile.Eisdir -> error.IsDirectory
    simplifile.Exdev -> error.CrossFilesystem
    _ -> error.UnknownIoFailure
  })
}

@external(erlang, "http_gun_file_ffi", "directory_name")
fn directory_name(destination: String) -> String

// simplifile.delete is recursive; cleanup must only remove an empty directory.
@external(erlang, "http_gun_file_ffi", "remove_directory")
pub fn remove_directory(path: String) -> Nil
