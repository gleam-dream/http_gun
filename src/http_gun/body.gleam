/// An owned byte stream. Copies share consumption state in one Gleam actor.
import gleam/bit_array
import gleam/erlang/process
import gleam/erlang/reference
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import gleam/string
import http_gun/cancellation
import http_gun/config
import http_gun/error.{type Failure, Failure, MayHaveBeenSent}
import http_gun/fixture
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/observation as obs
import http_gun/recording
import http_gun/telemetry

pub opaque type Body {
  Body(subject: process.Subject(Message), protocol: config.Negotiated)
}

pub type Event {
  Chunk(BitArray)
  End(trailers: List(#(String, String)))
}

pub type Collected {
  Collected(bytes: BitArray, trailers: List(#(String, String)))
}

type Reply =
  process.Subject(Result(Event, Failure))

type Phase {
  Opening(process.Subject(Result(response.Response(Body), Failure)))
  Reading
  Finished(Result(List(#(String, String)), Failure))
  Rejected(Failure)
}

type Waiting {
  Waiting(
    reply: Reply,
    until: Int,
    id: reference.Reference,
    timer: process.Timer,
  )
}

@internal
pub type Input {
  Live(process.Pid, config.Negotiated)
  Script(fixture.Reply)
}

type Source {
  Gun(process.Pid, bridge.Stream)
  Scripted(List(obs.Observation))
}

type CaptureState {
  NoCapture
  CaptureReady(recording.Capture, List(obs.Observation))
  CaptureWaiting(recording.Capture, List(obs.Observation))
}

type State {
  State(
    subject: process.Subject(Message),
    owner: process.Pid,
    client: process.Pid,
    source: Source,
    capture: CaptureState,
    protocol: config.Negotiated,
    deadline: Int,
    deadline_timer: process.Timer,
    cancellation_monitor: Option(process.Monitor),
    limits: config.Limits,
    phase: Phase,
    queue: List(BitArray),
    queued: Int,
    credit: Int,
    waiting: Option(Waiting),
    release: fn(Bool) -> Nil,
    observation: Option(telemetry.Context),
  )
}

type Message {
  Captured(Result(Nil, recording.CaptureError))
  Advance
  Read(process.Pid, Int, Reply)
  Close(process.Subject(Result(Nil, Failure)))
  Wire(bridge.Event)
  Deadline
  WaitExpired(reference.Reference)
  Lost(process.Down)
}

/// Read one chunk or completion with trailers. Only the opening process may read.
/// Copies share consumption; an overlapping read returns ReadConflict.
/// A local ReadTimeout preserves the stream and outstanding demand. Negative waits
/// poll as zero; the request deadline and cancellation still terminate unfinished work.
pub fn next(body: Body, wait_ms: Int) -> Result(Event, Failure) {
  call.run(body.subject, Read(
    process.self(),
    bridge.now() + int.max(0, wait_ms),
    _,
  ))
  |> result.map_error(fn(failure) {
    case failure.reason {
      error.ClientClosed -> Failure(error.Closed, MayHaveBeenSent)
      _ -> failure
    }
  })
}

/// Release this handle once and cancel unfinished HTTP locally. Idempotent.
/// Another holder may close it; this does not establish remote rollback.
pub fn close(body: Body) -> Result(Nil, Failure) {
  case call.run(body.subject, Close) {
    Error(Failure(error.ClientClosed, _)) -> Ok(Nil)
    outcome -> outcome
  }
}

/// Return the observed protocol, or Offline for scripted/replayed responses.
pub fn protocol(body: Body) -> config.Negotiated {
  body.protocol
}

/// Collect bytes and trailers up to limit, closing the body on overflow.
/// Other read failures propagate. The explicitly owned handle still needs close;
/// send and scoped response callbacks perform that cleanup for you.
pub fn collect(body: Body, limit: Int) -> Result(Collected, Failure) {
  collect_loop(body, limit, [], 0)
}

fn collect_loop(
  body: Body,
  limit: Int,
  chunks: List(BitArray),
  size: Int,
) -> Result(Collected, Failure) {
  use event <- result.try(next(body, 2_147_483_647))
  case event {
    End(trailers) ->
      Ok(Collected(bit_array.concat(list.reverse(chunks)), trailers))
    Chunk(bytes) ->
      case size + bit_array.byte_size(bytes) <= limit {
        True ->
          collect_loop(
            body,
            limit,
            [bytes, ..chunks],
            size + bit_array.byte_size(bytes),
          )
        False -> {
          let _ = close(body)
          Error(Failure(
            error.LimitExceeded(
              error.CollectedBodyBytes,
              limit,
              size + bit_array.byte_size(bytes),
            ),
            MayHaveBeenSent,
          ))
        }
      }
  }
}

/// Internal construction; hidden from generated public docs by package boundary.
@internal
pub fn start(
  client: process.Pid,
  input: Input,
  req: request.Request(BitArray),
  owner: process.Pid,
  deadline: Int,
  limits: config.Limits,
  reply: process.Subject(Result(response.Response(Body), Failure)),
  release: fn(Bool) -> Nil,
  capture: Option(recording.Capture),
  token: Option(cancellation.Token),
  observation: Option(telemetry.Context),
) -> actor.StartResult(Body) {
  actor.new_with_initialiser(1000, fn(subject) {
    let _ = process.monitor(client)
    let _ = process.monitor(owner)
    case capture {
      Some(cap) -> {
        let _ = process.monitor(recording.owner(cap))
        Nil
      }
      None -> Nil
    }
    use #(source, protocol) <- result.try(case input {
      Live(connection, protocol) -> {
        let _ = process.monitor(connection)
        let target =
          req.path
          <> case req.query {
            Some(query) -> "?" <> query
            None -> ""
          }
        use stream <- result.try(
          bridge.request(
            connection,
            http.method_to_string(req.method),
            target,
            wire_headers(req),
            req.body,
          )
          |> result.map_error(fn(_) { "request submission failed" }),
        )
        telemetry.emit(observation, telemetry.GunCallReturned)
        Ok(#(Gun(connection, stream), protocol))
      }
      Script(reply) -> Ok(#(Scripted(script_steps(reply)), config.Offline))
    })
    process.send(subject, Advance)
    let deadline_timer =
      process.send_after(subject, int.max(0, deadline - bridge.now()), Deadline)
    let state =
      State(
        subject,
        owner,
        client,
        source,
        case capture {
          Some(cap) -> CaptureReady(cap, [])
          None -> NoCapture
        },
        protocol,
        deadline,
        deadline_timer,
        option.map(token, cancellation.monitor),
        limits,
        Opening(reply),
        [],
        0,
        1,
        None,
        release,
        observation,
      )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(Lost)
      |> process.select_other(fn(value) { Wire(bridge.decode(value)) })
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(Body(subject, protocol)),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

// Gun's connection origin is the pinned IP. Keep HTTP authority bound to the
// original request unless the caller deliberately supplied a Host header.
fn wire_headers(req: request.Request(a)) -> List(#(String, String)) {
  case request.get_header(req, "host") {
    Ok(_) -> req.headers
    Error(_) -> [#("host", authority(req)), ..req.headers]
  }
}

@internal
pub fn authority(req: request.Request(a)) -> String {
  let bare = bridge.unbracket(req.host)
  let host = case string.contains(bare, ":") {
    True -> "[" <> bare <> "]"
    False -> bare
  }
  case req.port, req.scheme {
    None, _ | Some(443), http.Https | Some(80), http.Http -> host
    Some(port), _ -> host <> ":" <> int.to_string(port)
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let state = case
    bridge.now() >= state.deadline && capture_busy(state.capture)
  {
    True -> abandon_capture(state)
    False -> state
  }
  let state = case state.phase {
    Finished(_) | Rejected(_) -> state
    Opening(_) | Reading ->
      case bridge.now() >= state.deadline {
        True ->
          finish(state, Error(Failure(error.DeadlineExceeded, MayHaveBeenSent)))
        False -> state
      }
  }
  case message {
    Captured(outcome) -> {
      let capture = case state.capture, outcome {
        CaptureWaiting(cap, queue), Ok(Nil) -> CaptureReady(cap, queue)
        _, Error(_) -> NoCapture
        capture, Ok(Nil) -> capture
      }
      continue(State(..state, capture: capture))
    }
    Advance -> continue(step_script(state))
    Close(reply) -> {
      let state = finish(state, Error(Failure(error.Closed, MayHaveBeenSent)))
      flush_capture(state.capture)
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Lost(process.PortDown(..)) -> continue(state)
    Lost(process.ProcessDown(monitor: monitor, ..))
      if state.cancellation_monitor == Some(monitor)
    ->
      continue(
        deliver(finish(state, Error(Failure(error.Cancelled, MayHaveBeenSent)))),
      )
    Lost(process.ProcessDown(pid: pid, reason: reason, ..)) ->
      case pid == state.owner || pid == state.client {
        True -> {
          let state =
            finish(state, Error(Failure(error.Closed, MayHaveBeenSent)))
          flush_capture(state.capture)
          actor.stop()
        }
        False ->
          case is_capture_owner(state.capture, pid) {
            True -> continue(State(..state, capture: NoCapture))
            False ->
              continue(
                deliver(finish(
                  state,
                  Error(Failure(
                    error.ConnectionFailed(bridge.exit_cause(reason)),
                    MayHaveBeenSent,
                  )),
                )),
              )
          }
      }
    Deadline -> continue(deliver(state))
    Read(caller, until, reply) -> read(state, caller, until, reply) |> continue
    WaitExpired(id) ->
      case state.waiting {
        Some(Waiting(reply, _, expected, _)) if id == expected -> {
          process.send(
            reply,
            Error(Failure(error.ReadTimeout, MayHaveBeenSent)),
          )
          continue(State(..state, waiting: None))
        }
        _ -> continue(state)
      }
    Wire(event) -> continue(deliver(wire(state, event)))
  }
}

fn read(state: State, caller: process.Pid, until: Int, reply: Reply) -> State {
  case state.waiting {
    Some(_) -> {
      process.send(reply, Error(Failure(error.ReadConflict, MayHaveBeenSent)))
      state
    }
    None ->
      case caller == state.owner {
        False -> {
          process.send(reply, Error(Failure(error.WrongOwner, MayHaveBeenSent)))
          state
        }
        True -> {
          let id = reference.new()
          let timer =
            process.send_after(
              state.subject,
              int.max(0, until - bridge.now()),
              WaitExpired(id),
            )
          deliver(
            State(..state, waiting: Some(Waiting(reply, until, id, timer))),
          )
        }
      }
  }
}

fn deliver(state: State) -> State {
  let failed = case state.phase {
    Finished(Error(_)) | Rejected(_) -> True
    _ -> False
  }
  case capture_busy(state.capture) && !failed {
    True -> state
    False -> deliver_ready(state)
  }
}

fn deliver_ready(state: State) -> State {
  case state.waiting {
    None -> state
    Some(Waiting(reply, until, _, timer)) ->
      case state.queue {
        [bytes, ..rest] -> {
          let _ = process.cancel_timer(timer)
          process.send(reply, Ok(Chunk(bytes)))
          State(
            ..state,
            queue: rest,
            queued: state.queued - bit_array.byte_size(bytes),
            waiting: None,
          )
        }
        [] ->
          case state.phase {
            Rejected(failure) -> {
              process.send(reply, Error(failure))
              State(..state, waiting: None)
            }
            Finished(outcome) -> {
              let _ = process.cancel_timer(timer)
              process.send(reply, result.map(outcome, End))
              State(..state, waiting: None)
            }
            Opening(_) | Reading ->
              case bridge.now() >= until {
                True -> {
                  let _ = process.cancel_timer(timer)
                  process.send(
                    reply,
                    Error(Failure(error.ReadTimeout, MayHaveBeenSent)),
                  )
                  State(..state, waiting: None)
                }
                False ->
                  case state.credit <= 0 || state.protocol == config.Offline {
                    True -> {
                      case state.source {
                        Gun(connection, stream) -> {
                          bridge.credit(connection, stream, 1 - state.credit)
                          State(..state, credit: 1)
                        }
                        Scripted(_) -> deliver(step_script(state))
                      }
                    }
                    False -> state
                  }
              }
          }
      }
  }
}

fn wire(state: State, event: bridge.Event) -> State {
  case state.source {
    Scripted(_) -> state
    Gun(_, expected) ->
      case event {
        bridge.Head(ref, fin, status, headers) if ref == expected -> {
          let state = observe(state, obs.Head(status, headers))
          case fin {
            True -> observe(state, obs.Complete([]))
            False -> state
          }
        }
        bridge.Data(ref, fin, bytes) if ref == expected -> {
          let state =
            observe(State(..state, credit: state.credit - 1), obs.Bytes(bytes))
          case fin {
            True -> observe(state, obs.Complete([]))
            False -> state
          }
        }
        bridge.Trailers(ref, headers) if ref == expected ->
          observe(state, obs.Complete(headers))
        bridge.Inform(ref, headers) if ref == expected ->
          case check_headers(headers, state.limits, ResponseHeaders) {
            Ok(Nil) -> state
            Error(failure) -> finish(state, Error(failure))
          }
        bridge.Failed(ref, cause) if ref == expected ->
          observe(
            state,
            obs.Failed(Failure(error.RequestFailed(cause), MayHaveBeenSent)),
          )
        _ -> state
      }
  }
}

fn observe(state: State, event: obs.Observation) -> State {
  case state.phase {
    Finished(_) | Rejected(_) -> state
    Opening(_) | Reading ->
      case event {
        obs.Head(status, headers) ->
          case state.phase {
            Opening(reply) ->
              case check_headers(headers, state.limits, ResponseHeaders) {
                Error(failure) -> finish(state, Error(failure))
                Ok(Nil) -> {
                  telemetry.emit(
                    state.observation,
                    telemetry.ResponseHeaders(status),
                  )
                  process.send(
                    reply,
                    Ok(response.Response(
                      status,
                      headers,
                      Body(state.subject, state.protocol),
                    )),
                  )
                  capture_event(
                    State(..state, phase: Reading),
                    obs.Head(status, headers),
                  )
                }
              }
            Reading | Finished(_) | Rejected(_) -> state
          }
        obs.Bytes(bytes) -> {
          let size = bit_array.byte_size(bytes)
          case
            size > state.limits.chunk_bytes
            || state.queued + size > state.limits.queue_bytes
          {
            True ->
              finish(
                state,
                Error(Failure(
                  case size > state.limits.chunk_bytes {
                    True ->
                      error.LimitExceeded(
                        error.ResponseChunkBytes,
                        state.limits.chunk_bytes,
                        size,
                      )
                    False ->
                      error.LimitExceeded(
                        error.ResponseQueueBytes,
                        state.limits.queue_bytes,
                        state.queued + size,
                      )
                  },
                  MayHaveBeenSent,
                )),
              )
            False ->
              State(
                ..state,
                queue: case size {
                  0 -> state.queue
                  _ -> list.append(state.queue, [bytes])
                },
                queued: state.queued + size,
              )
              |> capture_bytes(bytes)
          }
        }
        obs.Complete(headers) ->
          case check_headers(headers, state.limits, ResponseHeaders) {
            Ok(Nil) -> finish(state, Ok(headers))
            Error(failure) -> finish(state, Error(failure))
          }
        obs.Failed(failure) -> finish(state, Error(failure))
      }
  }
}

fn step_script(state: State) -> State {
  case state.source {
    Gun(_, _) -> state
    Scripted([]) -> state
    Scripted([event, ..rest]) ->
      observe(State(..state, source: Scripted(rest)), event)
  }
}

fn script_steps(reply: fixture.Reply) -> List(obs.Observation) {
  case reply {
    fixture.Reject(failure) -> [obs.Failed(failure)]
    fixture.Respond(response, ending) -> {
      let last = case ending {
        fixture.Complete(trailers) -> obs.Complete(trailers)
        fixture.Failed(failure) -> obs.Failed(failure)
        fixture.Cancelled -> obs.Failed(Failure(error.Closed, MayHaveBeenSent))
      }
      [
        obs.Head(response.status, response.headers),
        ..list.append(list.map(response.body, obs.Bytes), [last])
      ]
    }
  }
}

fn finish(
  state: State,
  outcome: Result(List(#(String, String)), Failure),
) -> State {
  case state.phase {
    Finished(_) | Rejected(_) -> state
    Opening(reply) -> {
      let failure = case outcome {
        Error(failure) -> failure
        Ok(_) ->
          Failure(error.RequestFailed(error.UnknownTransport), MayHaveBeenSent)
      }
      telemetry.emit(state.observation, telemetry.termination(Error(failure)))
      process.send(reply, Error(failure))
      let state = capture_event(state, obs.Failed(failure))
      release(state, outcome)
      State(..state, phase: Rejected(failure))
    }
    Reading -> {
      telemetry.emit(state.observation, telemetry.termination(outcome))
      let state =
        capture_event(state, case outcome {
          Ok(headers) -> obs.Complete(headers)
          Error(failure) -> obs.Failed(failure)
        })
      release(state, outcome)
      State(..state, phase: Finished(outcome))
    }
  }
}

fn release(state: State, outcome: Result(a, Failure)) -> Nil {
  case state.cancellation_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  case capture_busy(state.capture) {
    False -> {
      let _ = process.cancel_timer(state.deadline_timer)
      Nil
    }
    True -> Nil
  }
  case outcome, state.source {
    Error(_), Gun(connection, stream) -> bridge.cancel(connection, stream)
    _, _ -> Nil
  }
  state.release(result.is_ok(outcome))
}

@internal
pub type HeaderKind {
  RequestHeaders
  ResponseHeaders
}

@internal
pub fn check_headers(
  headers: List(#(String, String)),
  limits: config.Limits,
  kind: HeaderKind,
) -> Result(Nil, Failure) {
  let bytes =
    list.fold(headers, 0, fn(total, pair) {
      total + string.byte_size(pair.0) + string.byte_size(pair.1)
    })
  let count = list.length(headers)
  let #(bytes_kind, count_kind) = case kind {
    RequestHeaders -> #(error.RequestHeaderBytes, error.RequestHeaderCount)
    ResponseHeaders -> #(error.ResponseHeaderBytes, error.ResponseHeaderCount)
  }
  case bytes > limits.head_bytes, count > limits.header_count {
    True, _ ->
      Error(Failure(
        error.LimitExceeded(bytes_kind, limits.head_bytes, bytes),
        MayHaveBeenSent,
      ))
    False, True ->
      Error(Failure(
        error.LimitExceeded(count_kind, limits.header_count, count),
        MayHaveBeenSent,
      ))
    False, False ->
      case
        list.all(headers, fn(pair) {
          result.is_ok(http.parse_method(pair.0))
          && valid_field_value(bit_array.from_string(pair.1))
        })
      {
        True -> Ok(Nil)
        False ->
          Error(Failure(
            case kind {
              RequestHeaders -> error.InvalidRequest("invalid header")
              ResponseHeaders -> error.RequestFailed(error.ProtocolError)
            },
            MayHaveBeenSent,
          ))
      }
  }
}

// Validate values delivered by Gun, including trailers/informational headers.
// This is application admission after parsing, not a second wire parser.
fn valid_field_value(bytes: BitArray) -> Bool {
  case bytes {
    <<>> -> True
    <<byte, rest:bits>> if byte == 9 || { byte >= 32 && byte != 127 } ->
      valid_field_value(rest)
    _ -> False
  }
}

fn continue(state: State) -> actor.Next(State, Message) {
  case state.phase {
    Rejected(_) -> {
      flush_capture(state.capture)
      actor.stop()
    }
    _ -> {
      let state = pump_capture(state)
      let state = deliver(state)
      case state.phase, capture_busy(state.capture) {
        Finished(_), False -> {
          let _ = process.cancel_timer(state.deadline_timer)
          Nil
        }
        _, _ -> Nil
      }
      actor.continue(state)
    }
  }
}

fn capture_event(state: State, event: obs.Observation) -> State {
  let capture = case state.capture {
    NoCapture -> NoCapture
    CaptureReady(cap, queue) -> CaptureReady(cap, list.append(queue, [event]))
    CaptureWaiting(cap, queue) ->
      CaptureWaiting(cap, list.append(queue, [event]))
  }
  State(..state, capture: capture)
}

fn capture_bytes(state: State, bytes: BitArray) -> State {
  case bit_array.byte_size(bytes) {
    0 -> state
    _ -> capture_event(state, obs.Bytes(bytes))
  }
}

fn pump_capture(state: State) -> State {
  case state.capture {
    CaptureReady(cap, [event, ..rest]) -> {
      let subject = state.subject
      recording.write(cap, event, fn(result) {
        process.send(subject, Captured(result))
      })
      State(..state, capture: CaptureWaiting(cap, rest))
    }
    _ -> state
  }
}

fn capture_busy(capture: CaptureState) -> Bool {
  case capture {
    NoCapture | CaptureReady(_, []) -> False
    _ -> True
  }
}

fn flush_capture(capture: CaptureState) -> Nil {
  case capture {
    NoCapture -> Nil
    CaptureReady(cap, events) | CaptureWaiting(cap, events) ->
      list.each(events, fn(event) { recording.write(cap, event, fn(_) { Nil }) })
  }
}

fn abandon_capture(state: State) -> State {
  case state.capture {
    NoCapture -> Nil
    CaptureReady(cap, _) | CaptureWaiting(cap, _) -> recording.abandon(cap)
  }
  State(..state, capture: NoCapture)
}

fn is_capture_owner(capture: CaptureState, pid: process.Pid) -> Bool {
  case capture {
    NoCapture -> False
    CaptureReady(cap, _) | CaptureWaiting(cap, _) -> recording.owner(cap) == pid
  }
}
