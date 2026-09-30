//// Recording coordination is a Gleam actor; a single linked IO worker executes
//// bounded writes. Disk work never blocks the coordinator's control mailbox.

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http/request
import gleam/int
import gleam/json
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import http_gun/error
import http_gun/fixture
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/codec
import http_gun/internal/file
import http_gun/internal/observation as obs

pub type Replacement {
  RefuseExisting
  ReplaceExisting
}

pub type Options {
  Options(max_bytes: Int, replacement: Replacement)
}

/// Capture at most 16 MiB of encoded data and refuse replacing an existing file.
/// Publication provides atomic visibility, without a power-loss durability guarantee.
pub fn default() -> Options {
  Options(16_777_216, RefuseExisting)
}

pub type CaptureError {
  CaptureLimit
  IoFailure(operation: error.FileOperation, cause: error.FileCause)
  DestinationExists
  SessionClosed
  Interrupted
}

pub type FinishError {
  Busy
  WaitTimeout
  CaptureFailed(CaptureError)
}

pub opaque type Recording {
  Recording(subject: process.Subject(Message), pid: process.Pid)
}

@internal
pub opaque type Capture {
  Capture(recording: Recording, id: Int)
}

type StreamState {
  AwaitHead
  Receiving(has_chunks: Bool)
  Ended
}

type Phase {
  Active
  Closing
  Sealing
  Sealed
  Broken(CaptureError)
}

type Publication {
  Publication(
    directory: String,
    destination: String,
    options: Options,
    count: Int,
  )
}

type Waiter {
  Waiter(
    reply: process.Subject(Result(String, FinishError)),
    id: reference.Reference,
    timer: Option(process.Timer),
    monitor: process.Monitor,
  )
}

type Job {
  Job(
    write: fn() -> Result(Nil, CaptureError),
    ack: fn(Result(Nil, CaptureError)) -> Nil,
  )
}

type Working {
  Working(pid: process.Pid, monitor: process.Monitor, job: Job)
}

type State {
  State(
    subject: process.Subject(Message),
    directory: String,
    destination: String,
    owner: process.Pid,
    client: Option(process.Pid),
    options: Options,
    streams: Dict(Int, StreamState),
    count: Int,
    bytes: Int,
    queue: List(Job),
    working: Option(Working),
    phase: Phase,
    waiter: Option(Waiter),
  )
}

type Message {
  AttachClient(process.Pid)
  Reserve(
    request.Request(BitArray),
    process.Subject(Result(Capture, CaptureError)),
  )
  Write(Int, obs.Observation, fn(Result(Nil, CaptureError)) -> Nil)
  Written(Result(Nil, CaptureError))
  Lost(process.Down)
  Finish(process.Subject(Result(String, FinishError)))
  FinishWait(Int, process.Subject(Result(String, FinishError)))
  WaitExpired(reference.Reference)
  Abandon
  Abort(process.Subject(Result(Nil, CaptureError)))
}

@internal
pub fn start(
  destination: String,
  options: Options,
) -> Result(Recording, CaptureError) {
  use Nil <- result.try(
    case
      options.max_bytes > 0
      && options.max_bytes <= 16_777_216
      && destination != ""
    {
      True -> Ok(Nil)
      False -> Error(CaptureLimit)
    },
  )
  use directory <- result.try(
    file.directory(destination) |> result.map_error(file_error),
  )
  let owner = process.self()
  let started =
    actor.new_with_initialiser(1000, fn(subject) {
      let _ = process.monitor(owner)
      let selector =
        process.new_selector()
        |> process.select(subject)
        |> process.select_monitors(Lost)
      Ok(
        actor.initialised(State(
          subject: subject,
          directory: directory,
          destination: destination,
          owner: owner,
          client: None,
          options: options,
          streams: dict.new(),
          count: 0,
          bytes: 64,
          queue: [],
          working: None,
          phase: Active,
          waiter: None,
        ))
        |> actor.selecting(selector)
        |> actor.returning(Recording(subject, process.self())),
      )
    })
    |> actor.on_message(handle)
    |> actor.start
  case started {
    Ok(started) -> Ok(started.data)
    Error(_) -> {
      file.remove_directory(directory)
      Error(Interrupted)
    }
  }
}

@internal
pub fn reserve(
  recording: Recording,
  req: request.Request(BitArray),
) -> Result(Capture, CaptureError) {
  call.with_failure(recording.subject, Reserve(req, _), Interrupted)
}

@internal
pub fn write(
  capture: Capture,
  observation: obs.Observation,
  ack: fn(Result(Nil, CaptureError)) -> Nil,
) -> Nil {
  process.send(capture.recording.subject, Write(capture.id, observation, ack))
}

@internal
pub fn owner(capture: Capture) -> process.Pid {
  capture.recording.pid
}

@internal
pub fn abandon(capture: Capture) -> Nil {
  process.send(capture.recording.subject, Abandon)
}

/// Busy is a refusal, not a successful partial fixture. After success or failure,
/// subsequent finish calls return the same outcome.
pub fn finish(recording: Recording) -> Result(String, FinishError) {
  call.with_failure(recording.subject, Finish, CaptureFailed(Interrupted))
}

/// Seal new reservations and await publication without consuming HTTP bodies.
/// A timeout removes this waiter only; finalization continues. Additional
/// concurrent waiters receive Busy. Calling again observes the stable outcome.
/// Negative waits poll immediately, as zero does. Abort explicitly abandons capture.
pub fn finish_wait(
  recording: Recording,
  wait_ms: Int,
) -> Result(String, FinishError) {
  call.with_failure(
    recording.subject,
    FinishWait(bridge.now() + int.max(0, wait_ms), _),
    CaptureFailed(Interrupted),
  )
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    AttachClient(pid) -> {
      let _ = process.monitor(pid)
      actor.continue(State(..state, client: Some(pid)))
    }
    Reserve(req, reply) -> reserve_request(state, req, reply) |> advance
    Write(id, event, ack) ->
      append_observation(state, id, event, ack) |> advance
    Written(outcome) -> {
      case state.working {
        Some(work) -> {
          process.demonitor_process(work.monitor)
          work.job.ack(outcome)
        }
        None -> Nil
      }
      let state = State(..state, working: None)
      case outcome {
        Error(failure) -> advance(break_session(state, failure))
        Ok(Nil) ->
          case state.phase {
            Sealing -> {
              let state = notify_waiter(state, Ok(state.destination))
              actor.continue(State(..state, phase: Sealed, streams: dict.new()))
            }
            Active | Closing | Sealed | Broken(_) -> advance(state)
          }
      }
    }
    Lost(process.ProcessDown(pid: pid, reason: reason, ..) as down) ->
      case
        pid == state.owner
        || { state.client == Some(pid) && reason != process.Normal }
      {
        True -> {
          let _ = break_session(state, Interrupted)
          actor.stop()
        }
        False ->
          case state.waiter {
            Some(waiter) if waiter.monitor == down.monitor ->
              advance(clear_waiter(state))
            _ ->
              case state.working {
                Some(work) if work.pid == pid -> {
                  work.job.ack(Error(Interrupted))
                  advance(break_session(
                    State(..state, working: None),
                    Interrupted,
                  ))
                }
                _ -> actor.continue(state)
              }
          }
      }
    Lost(process.PortDown(..)) -> actor.continue(state)
    Abandon -> advance(break_session(state, Interrupted))
    Abort(reply) -> {
      process.send(reply, Ok(Nil))
      advance(break_session(state, Interrupted))
    }
    Finish(reply) -> finish_session(state, reply)
    FinishWait(until, reply) ->
      await_finish(state, reply, Some(int.max(0, until - bridge.now())))
    WaitExpired(id) ->
      case state.waiter {
        Some(waiter) if waiter.id == id ->
          advance(notify_waiter(state, Error(WaitTimeout)))
        _ -> actor.continue(state)
      }
  }
}

fn reserve_request(
  state: State,
  req: request.Request(BitArray),
  reply: process.Subject(Result(Capture, CaptureError)),
) -> State {
  case state.phase {
    Active -> {
      let fragment =
        "{\"request\":"
        <> json.to_string(codec.request_json(req))
        <> ",\"reply\":"
      case
        state.count >= 10_000
        || state.bytes + string.byte_size(fragment) > state.options.max_bytes
      {
        True -> {
          process.send(reply, Error(CaptureLimit))
          break_session(state, CaptureLimit)
        }
        False -> {
          let id = state.count
          let path = exchange_path(state.directory, id)
          let job =
            Job(
              fn() {
                file.write_new(path, bit_array.from_string(fragment))
                |> result.map_error(file_error)
              },
              fn(_) { Nil },
            )
          let state =
            State(
              ..state,
              count: id + 1,
              streams: dict.insert(state.streams, id, AwaitHead),
              bytes: state.bytes + string.byte_size(fragment),
              queue: list.append(state.queue, [job]),
            )
          process.send(
            reply,
            Ok(Capture(Recording(state.subject, process.self()), id)),
          )
          state
        }
      }
    }
    Closing | Sealing | Sealed -> {
      process.send(reply, Error(SessionClosed))
      state
    }
    Broken(failure) -> {
      process.send(reply, Error(failure))
      state
    }
  }
}

fn append_observation(
  state: State,
  id: Int,
  event: obs.Observation,
  ack: fn(Result(Nil, CaptureError)) -> Nil,
) -> State {
  case state.phase {
    Broken(failure) -> {
      ack(Error(failure))
      state
    }
    Sealed | Sealing -> {
      ack(Error(SessionClosed))
      state
    }
    Active | Closing ->
      case dict.get(state.streams, id) {
        Error(Nil) -> {
          ack(Error(Interrupted))
          break_session(state, Interrupted)
        }
        Ok(stage) ->
          case fragment(stage, event) {
            Error(failure) -> {
              ack(Error(failure))
              break_session(state, failure)
            }
            Ok(#(text, stage)) ->
              case
                state.bytes + string.byte_size(text) + 1
                > state.options.max_bytes
              {
                True -> {
                  ack(Error(CaptureLimit))
                  break_session(state, CaptureLimit)
                }
                False -> {
                  let path = exchange_path(state.directory, id)
                  let job =
                    Job(
                      fn() {
                        file.append(path, bit_array.from_string(text))
                        |> result.map_error(file_error)
                      },
                      ack,
                    )
                  State(
                    ..state,
                    streams: dict.insert(state.streams, id, stage),
                    bytes: state.bytes + string.byte_size(text) + 1,
                    queue: list.append(state.queue, [job]),
                  )
                }
              }
          }
      }
  }
}

fn fragment(
  stage: StreamState,
  event: obs.Observation,
) -> Result(#(String, StreamState), CaptureError) {
  case stage, event {
    AwaitHead, obs.Head(status, headers) ->
      Ok(#(
        "{\"kind\":\"response\",\"status\":"
          <> int.to_string(status)
          <> ",\"headers\":"
          <> json.to_string(codec.headers_json(headers))
          <> ",\"chunks\":[",
        Receiving(False),
      ))
    Receiving(has_chunks), obs.Bytes(bytes) ->
      Ok(#(
        case has_chunks {
          True -> ","
          False -> ""
        }
          <> json.to_string(codec.bytes_json(bytes)),
        Receiving(True),
      ))
    Receiving(_), obs.Complete(headers) ->
      Ok(#(
        "],\"ending\":"
          <> json.to_string(codec.ending_json(fixture.Complete(headers)))
          <> "}}",
        Ended,
      ))
    Receiving(_), obs.Failed(failure) -> {
      let ending = case failure.reason {
        error.Closed -> fixture.Cancelled
        _ -> fixture.Failed(failure)
      }
      Ok(#(
        "],\"ending\":" <> json.to_string(codec.ending_json(ending)) <> "}}",
        Ended,
      ))
    }
    AwaitHead, obs.Failed(failure) ->
      Ok(#(
        json.to_string(codec.reply_json(fixture.Reject(failure))) <> "}",
        Ended,
      ))
    _, _ -> Error(Interrupted)
  }
}

fn advance(state: State) -> actor.Next(State, Message) {
  case state.phase, state.working, state.queue {
    Active, None, [job, ..rest]
    | Closing, None, [job, ..rest]
    | Sealing, None, [job, ..rest]
    -> {
      let subject = state.subject
      let write = job.write
      let pid = process.spawn(fn() { process.send(subject, Written(write())) })
      actor.continue(
        State(
          ..state,
          queue: rest,
          working: Some(Working(pid, process.monitor(pid), job)),
        ),
      )
    }
    Closing, None, [] ->
      case unfinished(state) {
        True -> actor.continue(state)
        False -> {
          let publication =
            Publication(
              state.directory,
              state.destination,
              state.options,
              state.count,
            )
          let job = Job(fn() { publish(publication) }, fn(_) { Nil })
          advance(State(..state, phase: Sealing, queue: [job]))
        }
      }
    _, _, _ -> actor.continue(state)
  }
}

fn break_session(state: State, failure: CaptureError) -> State {
  case state.phase {
    Sealed | Broken(_) -> state
    Active | Closing | Sealing -> {
      case state.working {
        Some(work) -> {
          process.unlink(work.pid)
          process.kill(work.pid)
          process.demonitor_process(work.monitor)
          work.job.ack(Error(failure))
        }
        None -> Nil
      }
      list.each(state.queue, fn(job) { job.ack(Error(failure)) })
      let state = notify_waiter(state, Error(CaptureFailed(failure)))
      State(..state, phase: Broken(failure), working: None, queue: [])
    }
  }
}

fn unfinished(state: State) -> Bool {
  state.working != None
  || state.queue != []
  || list.any(dict.values(state.streams), fn(stage) { stage != Ended })
}

fn finish_session(
  state: State,
  reply: process.Subject(Result(String, FinishError)),
) -> actor.Next(State, Message) {
  case state.phase, unfinished(state) {
    Active, True -> {
      process.send(reply, Error(Busy))
      actor.continue(state)
    }
    Closing, _ | Sealing, _ -> {
      process.send(reply, Error(Busy))
      actor.continue(state)
    }
    _, _ -> await_finish(state, reply, None)
  }
}

fn await_finish(
  state: State,
  reply: process.Subject(Result(String, FinishError)),
  wait_ms: Option(Int),
) -> actor.Next(State, Message) {
  case state.phase, state.waiter {
    Sealed, _ -> {
      process.send(reply, Ok(state.destination))
      actor.continue(state)
    }
    Broken(failure), _ -> {
      process.send(reply, Error(CaptureFailed(failure)))
      actor.continue(state)
    }
    _, Some(_) -> {
      process.send(reply, Error(Busy))
      actor.continue(state)
    }
    _, None -> {
      let phase = case state.phase {
        Active -> Closing
        other -> other
      }
      case process.subject_owner(reply) {
        Error(Nil) -> advance(State(..state, phase: phase))
        Ok(pid) -> {
          let id = reference.new()
          let timer =
            option.map(wait_ms, fn(ms) {
              process.send_after(state.subject, ms, WaitExpired(id))
            })
          advance(
            State(
              ..state,
              phase: phase,
              waiter: Some(Waiter(reply, id, timer, process.monitor(pid))),
            ),
          )
        }
      }
    }
  }
}

fn clear_waiter(state: State) -> State {
  case state.waiter {
    None -> state
    Some(waiter) -> {
      process.demonitor_process(waiter.monitor)
      case waiter.timer {
        Some(timer) -> {
          let _ = process.cancel_timer(timer)
          Nil
        }
        None -> Nil
      }
      State(..state, waiter: None)
    }
  }
}

fn notify_waiter(state: State, outcome: Result(String, FinishError)) -> State {
  case state.waiter {
    Some(waiter) -> process.send(waiter.reply, outcome)
    None -> Nil
  }
  clear_waiter(state)
}

fn publish(state: Publication) -> Result(Nil, CaptureError) {
  let output = state.directory <> "/complete.json"
  use Nil <- result.try(
    file.write_new(
      output,
      bit_array.from_string("{\"http_gun\":1,\"exchanges\":["),
    )
    |> result.map_error(file_error),
  )
  use Nil <- result.try(copy_exchanges(state, output, 0))
  use Nil <- result.try(
    file.append(output, <<"]}":utf8>>) |> result.map_error(file_error),
  )
  use Nil <- result.try(
    file.publish(
      output,
      state.destination,
      state.options.replacement == ReplaceExisting,
    )
    |> result.map_error(file_error),
  )
  cleanup(state)
  Ok(Nil)
}

fn copy_exchanges(
  state: Publication,
  output: String,
  index: Int,
) -> Result(Nil, CaptureError) {
  case index == state.count {
    True -> Ok(Nil)
    False -> {
      use bytes <- result.try(
        file.read(
          exchange_path(state.directory, index),
          state.options.max_bytes,
        )
        |> result.map_error(file_error),
      )
      let prefix = case index {
        0 -> <<>>
        _ -> <<",":utf8>>
      }
      use Nil <- result.try(
        file.append(output, <<prefix:bits, bytes:bits>>)
        |> result.map_error(file_error),
      )
      copy_exchanges(state, output, index + 1)
    }
  }
}

fn cleanup(state: Publication) -> Nil {
  int.range(0, state.count, Nil, fn(_, index) {
    file.remove(exchange_path(state.directory, index))
  })
  file.remove(state.directory <> "/complete.json")
  file.remove_directory(state.directory)
}

fn exchange_path(directory: String, id: Int) -> String {
  directory <> "/" <> int.to_string(id) <> ".json"
}

fn file_error(problem: file.FileError) -> CaptureError {
  case problem {
    file.Io(error.PublishFixture, error.AlreadyExists) -> DestinationExists
    file.TooLarge -> CaptureLimit
    file.Io(operation, cause) -> IoFailure(operation, cause)
  }
}

/// Abandon capture without cancelling the live HTTP client.
/// An already committed publication cannot be rolled back; finalized results stay final.
pub fn abort(recording: Recording) -> Result(Nil, CaptureError) {
  call.with_failure(recording.subject, Abort, Interrupted)
}

@internal
pub fn attach_client(recording: Recording, pid: process.Pid) -> Nil {
  process.send(recording.subject, AttachClient(pid))
}
