//// The body owner: one actor per response that submits the request, admits
//// the head and buffered bytes, arbitrates reads, timeouts and close, and
//// feeds a recording. `http_gun/body` is its public face.

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
import http_gun/error.{type Failure, MaybeSent}
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/lifecycle
import http_gun/internal/observation as obs
import http_gun/internal/recorder
import http_gun/internal/script
import http_gun/internal/settings
import http_gun/internal/token
import http_gun/telemetry

pub opaque type Body {
  Body(
    subject: process.Subject(Message),
    protocol: settings.Negotiated,
    status: Int,
  )
}

pub type Event {
  Chunk(BitArray)
  End(trailers: List(#(String, String)))
}

type Reply =
  process.Subject(Result(Option(Event), Failure))

type Phase {
  Opening(fn(Result(response.Response(Body), Failure)) -> Nil)
  Reading
  Finished(Result(List(#(String, String)), Failure))
  Rejected(Failure)
}

type Waiting {
  Waiting(
    reply: Reply,
    until: Option(Int),
    id: reference.Reference,
    timer: Option(process.Timer),
  )
}

pub type Input {
  Live(process.Pid, settings.Negotiated)
  Script(script.Reply)
}

type Source {
  Gun(process.Pid, bridge.Stream)
  Scripted(List(obs.Observation))
}

type CaptureState {
  NoCapture
  CaptureReady(recorder.Capture, List(obs.Observation))
  CaptureWaiting(recorder.Capture, List(obs.Observation))
}

/// Request timing as the pool resolved it for one invocation.
pub type Timing {
  Timing(deadline: Option(Int), idle: settings.Bound)
}

type State {
  State(
    subject: process.Subject(Message),
    owner: process.Pid,
    client: process.Pid,
    source: Source,
    capture: CaptureState,
    protocol: settings.Negotiated,
    persistent: Bool,
    deadline: Option(Int),
    deadline_timer: Option(process.Timer),
    idle: settings.Bound,
    idle_ref: Option(reference.Reference),
    activity: Int,
    cancellation_monitor: Option(process.Monitor),
    limits: settings.Limits,
    phase: Phase,
    status: Option(Int),
    queue: List(BitArray),
    queued: Int,
    credit: Int,
    waiting: Option(Waiting),
    release: fn(Bool) -> Nil,
    closed: fn() -> Nil,
    observation: lifecycle.Context,
  )
}

pub opaque type Message {
  Captured(Result(Nil, recorder.CaptureError))
  Advance
  Read(process.Pid, Option(Int), Reply)
  Close(process.Subject(Result(Nil, Failure)))
  Wire(bridge.Event)
  Deadline
  IdleExpired(reference.Reference)
  WaitExpired(reference.Reference)
  Lost(process.Down)
}

/// Wait for the next event. `until` bounds this wait only: when it passes,
/// `Ok(None)` returns and the stream stays intact.
pub fn read(body: Body, until: Option(Int)) -> Result(Option(Event), Failure) {
  call.run(body.subject, Read(process.self(), until, _))
  |> result.map_error(fn(failure) {
    case error.reason(failure) {
      error.ClientClosed ->
        error.new(error.Closed, MaybeSent) |> error.with_status(body.status)
      _ -> failure
    }
  })
}

pub fn close(body: Body) -> Nil {
  let _ = call.run(body.subject, Close)
  Nil
}

pub fn protocol(body: Body) -> settings.Negotiated {
  body.protocol
}

pub fn status(body: Body) -> Int {
  body.status
}

/// Collect up to `limit` body bytes. `truncate` keeps the first `limit`
/// bytes on overflow instead of failing. `charge` is offered each chunk's
/// size before it is kept; refusing closes the body and fails with the
/// failure it returns.
pub fn collect(
  body: Body,
  limit: Int,
  truncate: Bool,
  charge: fn(Int) -> Result(Nil, Failure),
) -> Result(#(BitArray, List(#(String, String)), Bool), Failure) {
  collect_loop(body, limit, truncate, charge, [], 0)
}

fn collect_loop(
  body: Body,
  limit: Int,
  truncate: Bool,
  charge: fn(Int) -> Result(Nil, Failure),
  chunks: List(BitArray),
  size: Int,
) -> Result(#(BitArray, List(#(String, String)), Bool), Failure) {
  use event <- result.try(read(body, None))
  case event {
    None -> collect_loop(body, limit, truncate, charge, chunks, size)
    Some(End(trailers)) ->
      Ok(#(bit_array.concat(list.reverse(chunks)), trailers, False))
    Some(Chunk(bytes)) -> {
      let total = size + bit_array.byte_size(bytes)
      case total <= limit, truncate {
        True, _ ->
          case charge(bit_array.byte_size(bytes)) {
            Ok(Nil) ->
              collect_loop(
                body,
                limit,
                truncate,
                charge,
                [bytes, ..chunks],
                total,
              )
            Error(failure) -> {
              close(body)
              Error(failure)
            }
          }
        False, False -> {
          close(body)
          Error(
            error.new(
              error.LimitExceeded(error.ResponseBodyBytes, limit, total),
              MaybeSent,
            )
            |> error.with_status(body.status),
          )
        }
        False, True -> {
          close(body)
          let prefix =
            bit_array.slice(bytes, 0, limit - size) |> result.unwrap(<<>>)
          case charge(bit_array.byte_size(prefix)) {
            Ok(Nil) ->
              Ok(#(bit_array.concat(list.reverse([prefix, ..chunks])), [], True))
            Error(failure) -> Error(failure)
          }
        }
      }
    }
  }
}

pub fn start(
  client: process.Pid,
  input: Input,
  req: fn() -> request.Request(BitArray),
  owner: process.Pid,
  timing: Timing,
  limits: settings.Limits,
  reply: fn(Result(response.Response(Body), Failure)) -> Nil,
  release: fn(Bool) -> Nil,
  closed: fn() -> Nil,
  capture: Option(recorder.Capture),
  token: Option(token.Token),
  observation: lifecycle.Context,
) -> actor.StartResult(Body) {
  actor.new_with_initialiser(1000, fn(subject) {
    let _ = process.monitor(client)
    let _ = process.monitor(owner)
    case capture {
      Some(cap) -> {
        let _ = process.monitor(recorder.owner(cap))
        Nil
      }
      None -> Nil
    }
    let request = req()
    use #(source, protocol) <- result.try(case input {
      Live(connection, protocol) -> {
        let _ = process.monitor(connection)
        let target =
          request.path
          <> case request.query {
            Some(query) -> "?" <> query
            None -> ""
          }
        use stream <- result.try(
          bridge.request(
            connection,
            http.method_to_string(request.method),
            target,
            wire_headers(request),
            request.body,
          )
          |> result.map_error(fn(_) { "request submission failed" }),
        )
        lifecycle.emit(observation, telemetry.GunCallReturned)
        Ok(#(Gun(connection, stream), protocol))
      }
      Script(reply) -> Ok(#(Scripted(script_steps(reply)), settings.Offline))
    })
    process.send(subject, Advance)
    let deadline_timer =
      option.map(timing.deadline, fn(at) {
        process.send_after(subject, int.max(0, at - bridge.now()), Deadline)
      })
    let state =
      State(
        subject:,
        owner:,
        client:,
        source:,
        capture: case capture {
          Some(cap) -> CaptureReady(cap, [])
          None -> NoCapture
        },
        protocol:,
        persistent: !wants_close(request.headers),
        deadline: timing.deadline,
        deadline_timer:,
        idle: timing.idle,
        idle_ref: None,
        activity: bridge.now(),
        cancellation_monitor: option.map(token, token.monitor),
        limits:,
        phase: Opening(reply),
        status: None,
        queue: [],
        queued: 0,
        credit: 1,
        waiting: None,
        release:,
        closed:,
        observation:,
      )
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(Lost)
      |> process.select_other(fn(value) { Wire(bridge.decode(value)) })
    Ok(
      actor.initialised(state)
      |> actor.selecting(selector)
      |> actor.returning(Body(subject, protocol, 0)),
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

// Connection persistence is application policy over already parsed headers.
// A close token wins even when mixed with other comma-separated tokens.
fn wants_close(headers: List(#(String, String))) -> Bool {
  list.any(headers, fn(header) {
    string.lowercase(header.0) == "connection"
    && list.any(string.split(header.1, ","), fn(token) {
      string.lowercase(string.trim(token)) == "close"
    })
  })
}

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

fn expired(state: State) -> Bool {
  case state.deadline {
    Some(at) -> bridge.now() >= at
    None -> False
  }
}

fn failure(state: State, reason: error.Reason) -> Failure {
  with_status(state, error.new(reason, MaybeSent))
}

fn with_status(state: State, failure: Failure) -> Failure {
  case state.status, error.status(failure) {
    Some(status), None -> error.with_status(failure, status)
    _, _ -> failure
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  let state = case expired(state) && capture_busy(state.capture) {
    True -> abandon_capture(state)
    False -> state
  }
  let state = case state.phase {
    Finished(_) | Rejected(_) -> state
    Opening(_) | Reading ->
      case expired(state) {
        True -> finish(state, Error(failure(state, error.DeadlineExceeded)))
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
      let state = finish(state, Error(failure(state, error.Closed)))
      flush_capture(state.capture)
      state.closed()
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Lost(process.PortDown(..)) -> continue(state)
    Lost(process.ProcessDown(monitor: monitor, ..))
      if state.cancellation_monitor == Some(monitor)
    -> continue(deliver(finish(state, Error(failure(state, error.Cancelled)))))
    Lost(process.ProcessDown(pid: pid, reason: reason, ..)) ->
      case pid == state.owner || pid == state.client {
        True -> {
          let state = finish(state, Error(failure(state, error.Closed)))
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
                  Error(failure(
                    state,
                    error.ConnectionFailed(bridge.exit_cause(reason)),
                  )),
                )),
              )
          }
      }
    Deadline -> continue(deliver(state))
    IdleExpired(id) ->
      case state.idle_ref, state.idle {
        Some(expected), settings.Within(ms) if id == expected -> {
          let state = State(..state, idle_ref: None)
          case
            demand_outstanding(state) && bridge.now() - state.activity >= ms
          {
            True ->
              continue(
                deliver(finish(state, Error(failure(state, error.IdleTimeout)))),
              )
            False -> continue(state)
          }
        }
        _, _ -> continue(state)
      }
    Read(caller, until, reply) ->
      read_request(state, caller, until, reply) |> continue
    WaitExpired(id) ->
      case state.waiting {
        Some(Waiting(reply, _, expected, _)) if id == expected -> {
          process.send(reply, Ok(None))
          continue(State(..state, waiting: None))
        }
        _ -> continue(state)
      }
    Wire(event) -> continue(deliver(wire(state, event)))
  }
}

// Bytes are owed to a waiting party: the opener awaits the head, or a reader
// waits on an empty queue of an unfinished body.
fn demand_outstanding(state: State) -> Bool {
  case state.phase, state.source {
    _, Scripted(_) -> False
    Opening(_), _ -> True
    Reading, _ -> option.is_some(state.waiting) && state.queue == []
    Finished(_), _ | Rejected(_), _ -> False
  }
}

fn read_request(
  state: State,
  caller: process.Pid,
  until: Option(Int),
  reply: Reply,
) -> State {
  case state.waiting {
    Some(_) -> {
      process.send(reply, Error(failure(state, error.ReadConflict)))
      state
    }
    None ->
      case caller == state.owner {
        False -> {
          process.send(reply, Error(failure(state, error.WrongOwner)))
          state
        }
        True -> {
          let id = reference.new()
          let timer =
            option.map(until, fn(at) {
              process.send_after(
                state.subject,
                int.max(0, at - bridge.now()),
                WaitExpired(id),
              )
            })
          deliver(
            State(
              ..state,
              activity: bridge.now(),
              waiting: Some(Waiting(reply, until, id, timer)),
            ),
          )
        }
      }
  }
}

fn cancel_timer(timer: Option(process.Timer)) -> Nil {
  case timer {
    Some(timer) -> {
      let _ = process.cancel_timer(timer)
      Nil
    }
    None -> Nil
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
          cancel_timer(timer)
          process.send(reply, Ok(Some(Chunk(bytes))))
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
              cancel_timer(timer)
              process.send(reply, Error(failure))
              State(..state, waiting: None)
            }
            Finished(outcome) -> {
              cancel_timer(timer)
              process.send(reply, result.map(outcome, fn(t) { Some(End(t)) }))
              State(..state, waiting: None)
            }
            Opening(_) | Reading -> {
              // Grant demand before honouring an expired local wait, so a
              // polling reader still makes progress.
              let state = request_data(state)
              case state.waiting, until {
                Some(waiting), Some(at) ->
                  case bridge.now() >= at {
                    True -> {
                      cancel_timer(waiting.timer)
                      process.send(waiting.reply, Ok(None))
                      State(..state, waiting: None)
                    }
                    False -> state
                  }
                _, _ -> state
              }
            }
          }
      }
  }
}

fn request_data(state: State) -> State {
  case state.credit <= 0 || state.protocol == settings.Offline {
    True ->
      case state.source {
        Gun(connection, stream) -> {
          bridge.credit(connection, stream, 1 - state.credit)
          State(..state, credit: 1)
        }
        Scripted(_) -> deliver(step_script(state))
      }
    False -> state
  }
}

fn wire(state: State, event: bridge.Event) -> State {
  case state.source {
    Scripted(_) -> state
    Gun(connection, expected) ->
      case event {
        bridge.Down(pid, cause) if pid == connection ->
          observe(state, obs.Failed(failure(state, error.RequestFailed(cause))))
        bridge.Head(ref, fin, status, headers) if ref == expected -> {
          let state =
            State(
              ..state,
              activity: bridge.now(),
              persistent: state.persistent && !wants_close(headers),
            )
          let state = observe(state, obs.Head(status, headers))
          case fin {
            True -> observe(state, obs.Complete([]))
            False -> state
          }
        }
        bridge.Data(ref, fin, bytes) if ref == expected -> {
          let state =
            observe(
              State(..state, activity: bridge.now(), credit: state.credit - 1),
              obs.Bytes(bytes),
            )
          case fin {
            True -> observe(state, obs.Complete([]))
            False -> state
          }
        }
        bridge.Trailers(ref, headers) if ref == expected ->
          observe(State(..state, activity: bridge.now()), obs.Complete(headers))
        bridge.Inform(ref, headers) if ref == expected ->
          case check_headers(headers, state.limits, ResponseHeaders) {
            Ok(Nil) -> State(..state, activity: bridge.now())
            Error(reason) -> finish(state, Error(failure(state, reason)))
          }
        bridge.Failed(ref, cause) if ref == expected ->
          observe(state, obs.Failed(failure(state, error.RequestFailed(cause))))
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
                Error(reason) -> finish(state, Error(failure(state, reason)))
                Ok(Nil) -> {
                  lifecycle.emit(
                    state.observation,
                    telemetry.ResponseHeaders(status),
                  )
                  reply(
                    Ok(response.Response(
                      status,
                      headers,
                      Body(state.subject, state.protocol, status),
                    )),
                  )
                  capture_event(
                    State(..state, phase: Reading, status: Some(status)),
                    obs.Head(status, headers),
                  )
                }
              }
            Reading | Finished(_) | Rejected(_) -> state
          }
        obs.Bytes(bytes) -> {
          let size = bit_array.byte_size(bytes)
          case state.queued + size > state.limits.buffered_bytes {
            True ->
              finish(
                state,
                Error(failure(
                  state,
                  error.LimitExceeded(
                    error.BufferedBytes,
                    state.limits.buffered_bytes,
                    state.queued + size,
                  ),
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
            Error(reason) -> finish(state, Error(failure(state, reason)))
          }
        obs.Failed(failure) -> finish(state, Error(with_status(state, failure)))
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

fn script_steps(reply: script.Reply) -> List(obs.Observation) {
  case reply {
    script.Reject(failure) -> [obs.Failed(failure)]
    script.Respond(status, headers, chunks, ending) -> {
      let last = case ending {
        script.Finished(trailers) -> obs.Complete(trailers)
        script.Aborted(failure) -> obs.Failed(failure)
        script.Abandoned -> obs.Failed(error.new(error.Closed, MaybeSent))
      }
      [
        obs.Head(status, headers),
        ..list.append(list.map(chunks, obs.Bytes), [last])
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
          error.new(error.RequestFailed(error.UnknownTransport), MaybeSent)
      }
      lifecycle.emit(state.observation, lifecycle.termination(Error(failure)))
      reply(Error(failure))
      let state = capture_event(state, obs.Failed(failure))
      release(state, outcome)
      State(..state, phase: Rejected(failure))
    }
    Reading -> {
      lifecycle.emit(state.observation, lifecycle.termination(outcome))
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
    False -> cancel_timer(state.deadline_timer)
    True -> Nil
  }
  case outcome, state.source {
    Error(_), Gun(connection, stream) -> bridge.cancel(connection, stream)
    _, _ -> Nil
  }
  state.release(result.is_ok(outcome) && state.persistent)
}

pub type HeaderKind {
  RequestHeaders
  ResponseHeaders
}

/// Admission of parsed headers: byte and count limits, token names and field
/// values. Returns the reason only; the caller chooses the evidence.
pub fn check_headers(
  headers: List(#(String, String)),
  limits: settings.Limits,
  kind: HeaderKind,
) -> Result(Nil, error.Reason) {
  let bytes =
    list.fold(headers, 0, fn(total, pair) {
      total + string.byte_size(pair.0) + string.byte_size(pair.1)
    })
  let count = list.length(headers)
  let #(bytes_kind, count_kind) = case kind {
    RequestHeaders -> #(error.RequestHeaderBytes, error.RequestHeaderCount)
    ResponseHeaders -> #(error.ResponseHeaderBytes, error.ResponseHeaderCount)
  }
  case bytes > limits.header_bytes, count > limits.header_count {
    True, _ ->
      Error(error.LimitExceeded(bytes_kind, limits.header_bytes, bytes))
    False, True ->
      Error(error.LimitExceeded(count_kind, limits.header_count, count))
    False, False ->
      case
        list.all(headers, fn(pair) {
          result.is_ok(http.parse_method(pair.0))
          && valid_field_value(bit_array.from_string(pair.1))
        })
      {
        True -> Ok(Nil)
        False ->
          Error(case kind {
            RequestHeaders -> error.InvalidRequest(error.InvalidHeader)
            ResponseHeaders -> error.RequestFailed(error.ProtocolError)
          })
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
        Finished(_), False -> cancel_timer(state.deadline_timer)
        _, _ -> Nil
      }
      actor.continue(arm_idle(state))
    }
  }
}

// One idle timer at a time, measured from the last byte or the start of the
// current wait. A stale timer finds its reference replaced and is ignored.
fn arm_idle(state: State) -> State {
  case state.idle, state.idle_ref, demand_outstanding(state) {
    settings.Within(ms), None, True -> {
      let id = reference.new()
      let _ =
        process.send_after(
          state.subject,
          int.max(0, state.activity + ms - bridge.now()),
          IdleExpired(id),
        )
      State(..state, idle_ref: Some(id))
    }
    _, Some(_), False -> State(..state, idle_ref: None)
    _, _, _ -> state
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
      recorder.write(cap, event, fn(result) {
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
      list.each(events, fn(event) { recorder.write(cap, event, fn(_) { Nil }) })
  }
}

fn abandon_capture(state: State) -> State {
  case state.capture {
    NoCapture -> Nil
    CaptureReady(cap, _) | CaptureWaiting(cap, _) -> recorder.abandon(cap)
  }
  State(..state, capture: NoCapture)
}

fn is_capture_owner(capture: CaptureState, pid: process.Pid) -> Bool {
  case capture {
    NoCapture -> False
    CaptureReady(cap, _) | CaptureWaiting(cap, _) -> recorder.owner(cap) == pid
  }
}
