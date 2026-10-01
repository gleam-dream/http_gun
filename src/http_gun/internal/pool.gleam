import gleam/bit_array
import gleam/dict.{type Dict}
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
import http_gun/body
import http_gun/cancellation
import http_gun/config
import http_gun/deadline
import http_gun/destination
import http_gun/error.{type Failure, Failure, NotSubmitted}
import http_gun/fixture
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/observation as obs
import http_gun/internal/pending.{type Origin, type Pending, Origin, Pending}
import http_gun/internal/preparation
import http_gun/internal/resolution
import http_gun/recording
import http_gun/request_options
import http_gun/telemetry

pub type Stats {
  Stats(connections: Int, bodies: Int, waiting: Int)
}

pub opaque type Client {
  Client(
    subject: process.Subject(Message),
    config: config.Config,
    correlation: Option(telemetry.Id),
  )
}

type Status {
  Resolving
  Connecting
  Ready(config.Negotiated, Int)
  Checking(process.Pid)
  Checked
}

type Connection {
  Connection(pid: process.Pid, origin: Origin, status: Status, used: Int)
}

type Owned {
  Owned(
    pid: process.Pid,
    body: body.Body,
    connection: Option(process.Pid),
    released: Bool,
  )
}

pub type Mode {
  Record(recording.Recording)
  Live
  Playback(remaining: List(fixture.Exchange), position: Int)
}

type State {
  State(
    subject: process.Subject(Message),
    mode: Mode,
    config: config.Config,
    connections: List(Connection),
    pending: pending.Queue,
    owners: Dict(process.Pid, Owned),
    observations: Option(telemetry.Emitter),
  )
}

type Message {
  Resolved(process.Pid, Result(resolution.Resolved, error.Reason))
  CheckedConnection(process.Pid, process.Pid, Result(Bool, error.Reason))
  Inspect(process.Subject(Result(Stats, Failure)))
  Open(
    request.Request(BitArray),
    Origin,
    Option(telemetry.Id),
    Option(cancellation.Token),
    process.Pid,
    Int,
    process.Subject(Result(response.Response(body.Body), Failure)),
  )
  Stop(process.Subject(Result(Nil, Failure)))
  Wire(bridge.Event)
  Lost(process.Down)
  Expire(reference.Reference)
  Release(process.Pid, Option(process.Pid), Bool)
}

pub fn snapshot(client: Client) -> Result(Stats, Failure) {
  call.run(client.subject, Inspect)
}

pub fn config(client: Client) -> config.Config {
  client.config
}

pub fn open(
  client: Client,
  req: request.Request(BitArray),
) -> Result(response.Response(body.Body), Failure) {
  open_with_options(client, req, request_options.default())
}

pub fn open_with_options(
  client: Client,
  req: request.Request(BitArray),
  options: request_options.Options,
) -> Result(response.Response(body.Body), Failure) {
  use Nil <- result.try(case request_options.cancelled(options) {
    True -> Error(Failure(error.Cancelled, NotSubmitted))
    False -> Ok(Nil)
  })
  let until = case options.deadline {
    None -> bridge.now() + client.config.deadline_ms
    Some(budget) ->
      int.min(
        bridge.now() + client.config.deadline_ms,
        deadline.timestamp(budget),
      )
  }
  use Nil <- result.try(case until <= bridge.now() {
    True -> Error(Failure(error.DeadlineExceeded, NotSubmitted))
    False -> Ok(Nil)
  })
  let req = case req.path {
    "" -> request.Request(..req, path: "/")
    _ -> req
  }
  use origin <- result.try(validate(req, client.config.limits))
  call.with_failure(
    client.subject,
    Open(
      req,
      origin,
      client.correlation,
      options.cancellation,
      process.self(),
      until,
      _,
    ),
    Failure(error.ClientClosed, error.MayHaveBeenSent),
  )
}

pub fn stop(client: Client) -> Result(Nil, Failure) {
  call.run(client.subject, Stop)
}

pub fn start(settings: config.Config) -> actor.StartResult(Client) {
  start_mode(settings, Live)
}

pub fn start_mode(
  settings: config.Config,
  mode: Mode,
) -> actor.StartResult(Client) {
  use settings <- result.try(
    config.validate(settings) |> result.map_error(actor.InitFailed),
  )
  use Nil <- result.try(
    case mode {
      Live | Record(_) -> bridge.start()
      Playback(_, _) -> Ok(Nil)
    }
    |> result.map_error(fn(_) {
      actor.InitFailed("Gun application could not start")
    }),
  )
  actor.new_with_initialiser(1000, fn(subject) {
    let selector =
      process.new_selector()
      |> process.select(subject)
      |> process.select_monitors(Lost)
      |> process.select_other(fn(value) { Wire(bridge.decode(value)) })
    Ok(
      actor.initialised(State(
        subject,
        mode,
        settings,
        [],
        pending.new(),
        dict.new(),
        telemetry.prepare(settings.observations),
      ))
      |> actor.selecting(selector)
      |> actor.returning(Client(subject, settings, None)),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn origin(req: request.Request(a)) -> Origin {
  let tls = req.scheme == http.Https
  Origin(
    bridge.unbracket(string.lowercase(req.host)),
    option_port(req, tls),
    tls,
  )
}

fn option_port(req: request.Request(a), tls: Bool) -> Int {
  case req.port {
    Some(port) -> port
    None ->
      case tls {
        True -> 443
        False -> 80
      }
  }
}

fn handle(state: State, message: Message) -> actor.Next(State, Message) {
  case message {
    CheckedConnection(connection, worker, result) ->
      actor.continue(dispatch(checked(state, connection, worker, result)))
    Resolved(pid, result) ->
      actor.continue(dispatch(resolved(state, pid, result)))
    Inspect(reply) -> {
      process.send(
        reply,
        Ok(Stats(
          list.length(state.connections),
          dict.size(state.owners),
          pending.waiting(state.pending),
        )),
      )
      actor.continue(state)
    }
    Stop(reply) -> {
      list.each(pending.values(state.pending), fn(p) {
        reject(p, error.ClientClosed)
      })
      dict.each(state.owners, fn(_, o) {
        let _ = body.close(o.body)
        Nil
      })
      list.each(state.connections, close_connection)
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Open(req, origin, correlation, token, owner, deadline, reply) ->
      open_request(
        state,
        req,
        origin,
        correlation,
        token,
        owner,
        deadline,
        reply,
      )
    Expire(id) -> {
      let #(expired, queue) = pending.remove(state.pending, id)
      case expired {
        None -> actor.continue(state)
        Some(p) -> {
          reject(p, error.DeadlineExceeded)
          actor.continue(
            dispatch(discard_reservation(State(..state, pending: queue), p)),
          )
        }
      }
    }
    Release(pid, connection, clean) ->
      release_body(state, pid, connection, clean)
    Lost(process.PortDown(..)) -> actor.continue(state)
    Lost(process.ProcessDown(pid: pid, monitor: monitor, reason: reason)) -> {
      let #(cancelled, queue) =
        pending.remove_cancellation(state.pending, monitor)
      case cancelled {
        Some(p) -> {
          reject(p, error.Cancelled)
          actor.continue(
            dispatch(discard_reservation(State(..state, pending: queue), p)),
          )
        }
        None -> process_lost(state, pid, bridge.exit_cause(reason))
      }
    }
    Wire(bridge.Up(pid, protocol)) ->
      case
        state.config.protocol == config.RequireHttp2 && protocol != config.H2
      {
        True -> handle(state, Wire(bridge.Down(pid, error.UnexpectedProtocol)))
        False -> {
          // Wait for initial SETTINGS before admitting H2 application streams.
          let capacity = case protocol {
            config.H1 -> 1
            _ -> 0
          }
          let connections =
            list.map(state.connections, fn(c) {
              case c.pid == pid {
                True ->
                  Connection(..c, status: case protocol {
                    config.H1 -> Checked
                    config.H2 | config.Offline -> Ready(protocol, capacity)
                  })
                False -> c
              }
            })
          actor.continue(dispatch(State(..state, connections: connections)))
        }
      }
    Wire(bridge.Capacity(pid, capacity)) -> {
      let connections =
        list.map(state.connections, fn(c) {
          case c.pid == pid {
            True ->
              Connection(
                ..c,
                status: Ready(
                  config.H2,
                  int.min(capacity, state.config.limits.streams_per_connection),
                ),
              )
            False -> c
          }
        })
      actor.continue(dispatch(State(..state, connections: connections)))
    }
    Wire(bridge.Down(pid, cause)) ->
      actor.continue(dispatch(connection_lost(state, pid, cause)))
    Wire(_) -> actor.continue(state)
  }
}

fn reject(p: Pending, reason: error.Reason) -> Nil {
  reject_with(p, Failure(reason, NotSubmitted))
}

fn reject_with(p: Pending, failure: Failure) -> Nil {
  telemetry.emit(p.observation, telemetry.termination(Error(failure)))
  case p.capture {
    Some(cap) -> recording.write(cap, obs.Failed(failure), fn(_) { Nil })
    None -> Nil
  }
  let _ = process.cancel_timer(p.timer)
  case p.cancel_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  process.demonitor_process(p.monitor)
  process.send(p.reply, Error(failure))
}

// A deferred head blocks only its origin. Playback uses one session lane.
type Admission {
  Taken(State)
  Deferred(State, Pending)
}

fn group(state: State, p: Pending) -> pending.Group {
  case state.mode {
    Playback(_, _) -> pending.Session
    Live | Record(_) -> pending.ForOrigin(p.origin)
  }
}

fn dispatch(state: State) -> State {
  let state = list.fold(pending.groups(state.pending), state, dispatch_group)
  // Readiness is usable only by this admission pass. If body capacity or a
  // cancelled waiter prevents launch, do not cache an old liveness observation.
  State(
    ..state,
    connections: list.map(state.connections, fn(c) {
      case c.status {
        Checked -> Connection(..c, status: Ready(config.H1, 1))
        _ -> c
      }
    }),
  )
}

fn dispatch_group(state: State, group: pending.Group) -> State {
  case pending.first(state.pending, group) {
    Error(_) -> state
    Ok(p) ->
      case admit(state, p) {
        Deferred(next, p) ->
          State(..next, pending: pending.replace(next.pending, p))
        Taken(next) -> {
          let #(_, queue) = pending.remove(next.pending, p.id)
          dispatch_group(
            discard_reservation(
              State(..next, pending: pending.rotate(queue, group)),
              p,
            ),
            group,
          )
        }
      }
  }
}

fn admit_live(state: State, p: Pending) -> Admission {
  let permitted =
    destination.permits_host(state.config.destination, p.origin.host)
  case permitted {
    False -> {
      reject(p, error.DestinationRejected)
      Taken(state)
    }
    True -> admit_connection(state, p)
  }
}

fn admit_connection(state: State, p: Pending) -> Admission {
  let eligible =
    list.find(state.connections, fn(c) {
      c.origin == p.origin
      && case c.status {
        Resolving | Connecting | Checking(_) -> False
        Checked -> True
        Ready(_, capacity) -> c.used < capacity
      }
    })
  case eligible {
    Ok(Connection(status: Ready(config.H1, _), ..) as connection) -> {
      let subject = state.subject
      let pid = connection.pid
      let worker =
        preparation.start(
          process.self(),
          p.deadline,
          error.ConnectionFailed(error.UnknownTransport),
          fn() { Ok(bridge.reusable(pid)) },
          fn(worker, result) {
            process.send(subject, CheckedConnection(pid, worker, result))
          },
        )
      let _ = process.monitor(worker)
      Deferred(
        State(
          ..state,
          connections: list.map(state.connections, fn(c) {
            case c.pid == pid {
              True -> Connection(..c, status: Checking(worker))
              False -> c
            }
          }),
        ),
        Pending(..p, reservation: Some(pid)),
      )
    }
    Ok(connection) -> Taken(launch(state, p, connection))
    Error(Nil) -> {
      let state = make_room(state, p.origin)
      let same = list.filter(state.connections, fn(c) { c.origin == p.origin })
      case
        list.length(state.connections) < state.config.limits.connections
        && list.length(same) < state.config.limits.per_origin
        && !list.any(same, fn(c) { preparing(c.status) })
      {
        False -> Deferred(state, p)
        True -> {
          let subject = state.subject
          let pid =
            resolution.start(
              process.self(),
              state.config.destination,
              p.origin.host,
              p.deadline,
              fn(pid, result) { process.send(subject, Resolved(pid, result)) },
            )
          let _ = process.monitor(pid)
          Deferred(
            State(..state, connections: [
              Connection(pid, p.origin, Resolving, 0),
              ..state.connections
            ]),
            Pending(..p, reservation: Some(pid)),
          )
        }
      }
    }
  }
}

fn launch(state: State, p: Pending, connection: Connection) -> State {
  telemetry.emit(p.observation, telemetry.AdmissionGranted)
  let protocol = case connection.status {
    Ready(protocol, _) -> protocol
    Resolving | Connecting | Checking(_) | Checked -> config.H1
  }
  // This callback crosses a process boundary. Capture only its destinations,
  // never the pool state (which also contains every queued request).
  let subject = state.subject
  let connection_pid = connection.pid
  let release = fn(clean) {
    process.send(subject, Release(process.self(), Some(connection_pid), clean))
  }
  case
    body.start(
      process.self(),
      body.Live(connection.pid, protocol),
      p.request,
      p.owner,
      p.deadline,
      state.config.limits,
      p.reply,
      release,
      p.capture,
      p.cancellation,
      p.observation,
    )
  {
    Error(_) -> {
      reject_with(
        p,
        Failure(
          error.RequestFailed(error.UnknownTransport),
          error.MayHaveBeenSent,
        ),
      )
      bridge.close(connection.pid)
      State(
        ..state,
        connections: list.filter(state.connections, fn(c) {
          c.pid != connection.pid
        }),
      )
    }
    Ok(started) -> {
      process.unlink(started.pid)
      let _ = process.monitor(started.pid)
      case p.cancel_monitor {
        Some(monitor) -> process.demonitor_process(monitor)
        None -> Nil
      }
      process.demonitor_process(p.monitor)
      let _ = process.cancel_timer(p.timer)
      State(
        ..state,
        owners: dict.insert(
          state.owners,
          started.pid,
          Owned(started.pid, started.data, Some(connection.pid), False),
        ),
        connections: list.map(state.connections, fn(c) {
          case c.pid == connection.pid {
            True ->
              Connection(..c, used: c.used + 1, status: case c.status {
                Checked -> Ready(config.H1, 1)
                other -> other
              })
            False -> c
          }
        }),
      )
    }
  }
}

fn validate(
  req: request.Request(BitArray),
  limits: config.Limits,
) -> Result(Origin, Failure) {
  use Nil <- result.try(case bit_array.bit_size(req.body) % 8 == 0 {
    True -> Ok(Nil)
    False ->
      Error(Failure(
        error.InvalidRequest("body must contain whole bytes"),
        NotSubmitted,
      ))
  })
  let origin = origin(req)
  case
    origin.host != ""
    && origin.port > 0
    && origin.port <= 65_535
    && safe_target(origin.host)
    && http.parse_method(http.method_to_string(req.method)) |> result.is_ok
    && safe_target(option.unwrap(req.query, ""))
    && safe_target(req.path)
    && string.starts_with(req.path, "/")
    && !string.contains(req.path, "\r")
    && !string.contains(req.path, "\n")
    && list.all(req.headers, fn(h) {
      h.0 == string.lowercase(h.0)
      && http.parse_method(h.0) |> result.is_ok
      && !string.contains(h.1, "\r")
      && !string.contains(h.1, "\n")
      && !string.contains(h.1, "\u{0}")
    })
  {
    False ->
      Error(Failure(
        error.InvalidRequest("invalid origin, target or header"),
        NotSubmitted,
      ))
    True ->
      case bit_array.byte_size(req.body) <= limits.request_bytes {
        False ->
          Error(Failure(
            error.LimitExceeded(
              error.RequestBodyBytes,
              limits.request_bytes,
              bit_array.byte_size(req.body),
            ),
            NotSubmitted,
          ))
        True ->
          body.check_headers(req.headers, limits, body.RequestHeaders)
          |> result.map_error(fn(f) { Failure(f.reason, NotSubmitted) })
          |> result.map(fn(_) { origin })
      }
  }
}

fn admit(state: State, p: Pending) -> Admission {
  let cancelled = case p.cancellation {
    None -> False
    Some(token) -> cancellation.is_cancelled(token)
  }
  case cancelled, bridge.now() >= p.deadline {
    True, _ -> {
      reject(p, error.Cancelled)
      Taken(state)
    }
    False, True -> {
      reject(p, error.DeadlineExceeded)
      Taken(state)
    }
    False, False ->
      case
        dict.size(state.owners) + checking_count(state)
        >= state.config.limits.active
      {
        True -> Deferred(state, p)
        False ->
          case state.mode {
            Live | Record(_) -> admit_live(state, p)
            Playback(exchanges, position) ->
              Taken(admit_playback(state, p, exchanges, position))
          }
      }
  }
}

// Reserve admission capacity while checking an H1 lease. Concurrent checks
// cannot overtake one another when only one active slot is available.
fn checking_count(state: State) -> Int {
  list.count(state.connections, fn(c) {
    case c.status {
      Checking(_) -> True
      _ -> False
    }
  })
}

fn admit_playback(
  state: State,
  p: Pending,
  exchanges: List(fixture.Exchange),
  position: Int,
) -> State {
  case exchanges {
    [] -> {
      reject(p, error.FixtureExhausted)
      state
    }
    [exchange, ..rest] ->
      case fixture.matches(exchange.request, p.request) {
        False -> {
          reject(p, error.FixtureMismatch(position))
          state
        }
        True -> {
          telemetry.emit(p.observation, telemetry.AdmissionGranted)
          let subject = state.subject
          let release = fn(clean) {
            process.send(subject, Release(process.self(), None, clean))
          }
          case
            body.start(
              process.self(),
              body.Script(exchange.reply),
              p.request,
              p.owner,
              p.deadline,
              state.config.limits,
              p.reply,
              release,
              None,
              p.cancellation,
              p.observation,
            )
          {
            Error(_) -> {
              reject(p, error.RequestFailed(error.UnknownTransport))
              state
            }
            Ok(started) -> {
              process.unlink(started.pid)
              let _ = process.monitor(started.pid)
              case p.cancel_monitor {
                Some(monitor) -> process.demonitor_process(monitor)
                None -> Nil
              }
              process.demonitor_process(p.monitor)
              let _ = process.cancel_timer(p.timer)
              State(
                ..state,
                mode: Playback(rest, position + 1),
                owners: dict.insert(
                  state.owners,
                  started.pid,
                  Owned(started.pid, started.data, None, False),
                ),
              )
            }
          }
        }
      }
  }
}

fn reserve_capture(
  mode: Mode,
  req: request.Request(BitArray),
) -> Result(Option(recording.Capture), Failure) {
  case mode {
    Live | Playback(_, _) -> Ok(None)
    Record(recorder) ->
      case recording.reserve(recorder, req) {
        Ok(cap) -> Ok(Some(cap))
        Error(recording.SessionClosed) ->
          Error(Failure(
            error.CaptureFailed("recording is closing or finalized"),
            NotSubmitted,
          ))
        Error(_) -> Ok(None)
      }
  }
}

fn safe_target(value: String) -> Bool {
  !list.any([" ", "\r", "\n", "\t", "\u{0}"], fn(char) {
    string.contains(value, char)
  })
}

// Idle sockets are a cache, never a permanent claim on global capacity.
fn make_room(state: State, wanted: Origin) -> State {
  case list.length(state.connections) >= state.config.limits.connections {
    False -> state
    True ->
      case
        list.find(state.connections, fn(c) {
          c.origin != wanted
          && c.used == 0
          && !preparing(c.status)
          && !pending.has_group(state.pending, pending.ForOrigin(c.origin))
        })
      {
        Error(_) -> state
        Ok(idle) -> {
          bridge.close(idle.pid)
          State(
            ..state,
            connections: list.filter(state.connections, fn(c) {
              c.pid != idle.pid
            }),
          )
        }
      }
  }
}

fn open_request(
  state: State,
  req: request.Request(BitArray),
  origin: Origin,
  correlation: Option(telemetry.Id),
  token: Option(cancellation.Token),
  owner: process.Pid,
  deadline: Int,
  reply: process.Subject(Result(response.Response(body.Body), Failure)),
) -> actor.Next(State, Message) {
  let observation =
    telemetry.begin(state.observations, correlation, case state.mode {
      Live -> telemetry.Live
      Record(_) -> telemetry.Recorded
      Playback(_, _) -> telemetry.Offline
    })
  case reserve_capture(state.mode, req) {
    Error(failure) -> {
      telemetry.emit(observation, telemetry.termination(Error(failure)))
      process.send(reply, Error(failure))
      actor.continue(state)
    }
    Ok(capture) -> {
      let id = reference.new()
      let timer =
        process.send_after(
          state.subject,
          int.max(0, deadline - bridge.now()),
          Expire(id),
        )
      let p =
        Pending(
          id,
          owner,
          req,
          origin,
          reply,
          deadline,
          process.monitor(owner),
          timer,
          None,
          capture,
          token,
          option.map(token, cancellation.monitor),
          observation,
        )
      let group = group(state, p)
      // Never let a new arrival overtake an existing head in its lane.
      let admission = case pending.has_group(state.pending, group) {
        True -> Deferred(state, p)
        False -> admit(state, p)
      }
      case admission {
        Taken(next) -> actor.continue(next)
        Deferred(next, p) ->
          case
            p.reservation == None
            && pending.waiting(next.pending) >= state.config.limits.waiting
          {
            True -> {
              reject(p, error.AdmissionFull)
              actor.continue(next)
            }
            False -> {
              telemetry.emit(p.observation, telemetry.AdmissionWaiting)
              actor.continue(
                State(..next, pending: pending.push(next.pending, group, p)),
              )
            }
          }
      }
    }
  }
}

fn release_body(
  state: State,
  pid: process.Pid,
  connection: Option(process.Pid),
  clean: Bool,
) -> actor.Next(State, Message) {
  case dict.get(state.owners, pid) {
    Error(_) | Ok(Owned(released: True, ..)) -> actor.continue(state)
    Ok(owner) -> {
      let connections =
        list.filter_map(state.connections, fn(c) {
          case Some(c.pid) == connection {
            False -> Ok(c)
            True ->
              case c.status, clean {
                Ready(config.H1, _), False -> {
                  bridge.close(c.pid)
                  Error(Nil)
                }
                _, _ -> Ok(Connection(..c, used: int.max(0, c.used - 1)))
              }
          }
        })
      actor.continue(dispatch(
        State(
          ..state,
          connections: connections,
          owners: dict.insert(state.owners, pid, Owned(..owner, released: True)),
        ),
      ))
    }
  }
}

fn fail_group(
  state: State,
  group: pending.Group,
  cause: error.TransportCause,
) -> State {
  fail_reason(state, group, error.ConnectionFailed(cause))
}

fn connection_lost(
  state: State,
  pid: process.Pid,
  cause: error.TransportCause,
) -> State {
  case list.find(state.connections, fn(c) { c.pid == pid }) {
    Error(_) -> state
    Ok(connection) -> {
      close_connection(connection)
      let state =
        State(
          ..state,
          connections: list.filter(state.connections, fn(c) { c.pid != pid }),
        )
      case connection.status {
        Resolving ->
          fail_reason(
            state,
            pending.ForOrigin(connection.origin),
            error.ResolutionFailed,
          )
        Connecting ->
          fail_group(state, pending.ForOrigin(connection.origin), cause)
        Ready(_, _) | Checking(_) | Checked -> state
      }
    }
  }
}

fn process_lost(
  state: State,
  pid: process.Pid,
  cause: error.TransportCause,
) -> actor.Next(State, Message) {
  let lost = case
    list.find(state.connections, fn(c) { c.status == Checking(pid) })
  {
    Ok(connection) -> connection.pid
    Error(_) -> pid
  }
  let state = connection_lost(state, lost, cause)
  let #(cancelled, queue) = pending.remove_owner(state.pending, pid)
  case cancelled {
    Some(p) -> reject(p, error.Closed)
    None -> Nil
  }
  let state = State(..state, pending: queue)
  let state = case cancelled {
    Some(p) -> discard_reservation(state, p)
    None -> state
  }
  let next = case dict.get(state.owners, pid) {
    Ok(Owned(connection: Some(connection), released: False, ..)) ->
      connection_lost(state, connection, error.UnknownTransport)
    _ -> state
  }
  actor.continue(dispatch(State(..next, owners: dict.delete(next.owners, pid))))
}

// A cancelled connecting reservation is not an idle established cache entry.
// Keep it only while another queued request to that origin can use it.
fn discard_reservation(state: State, p: Pending) -> State {
  case pending.has_group(state.pending, pending.ForOrigin(p.origin)) {
    True -> state
    False -> {
      let #(unused, keep) =
        list.partition(state.connections, fn(connection) {
          connection.origin == p.origin && preparing(connection.status)
        })
      list.each(unused, close_connection)
      State(..state, connections: keep)
    }
  }
}

pub fn with_correlation(client: Client, id: telemetry.Id) -> Client {
  Client(..client, correlation: Some(id))
}

fn preparing(status: Status) -> Bool {
  case status {
    Resolving | Connecting | Checking(_) -> True
    Ready(_, _) | Checked -> False
  }
}

fn close_connection(connection: Connection) -> Nil {
  case connection.status {
    Resolving -> process.kill(connection.pid)
    Checking(worker) -> {
      process.kill(worker)
      bridge.close(connection.pid)
    }
    Connecting | Ready(_, _) | Checked -> bridge.close(connection.pid)
  }
}

fn fail_reason(
  state: State,
  group: pending.Group,
  reason: error.Reason,
) -> State {
  case pending.first(state.pending, group) {
    Error(_) -> state
    Ok(p) -> {
      reject(p, reason)
      let #(_, queue) = pending.remove(state.pending, p.id)
      fail_reason(State(..state, pending: queue), group, reason)
    }
  }
}

fn resolved(
  state: State,
  pid: process.Pid,
  answer: Result(resolution.Resolved, error.Reason),
) -> State {
  case
    list.find(state.connections, fn(c) { c.pid == pid && c.status == Resolving })
  {
    Error(_) -> state
    Ok(connection) -> {
      let without =
        State(
          ..state,
          connections: list.filter(state.connections, fn(c) { c.pid != pid }),
        )
      let group = pending.ForOrigin(connection.origin)
      case answer, pending.first(state.pending, group) {
        _, Error(_) -> without
        Error(error.DeadlineExceeded), _ -> without
        Error(reason), _ -> fail_reason(without, group, reason)
        Ok(target), Ok(p) -> {
          case p.deadline <= bridge.now() {
            True -> without
            False ->
              case
                bridge.open(
                  target.address,
                  target.server_name,
                  p.origin.port,
                  p.origin.tls,
                  state.config.protocol,
                  state.config.trust,
                  int.min(state.config.connect_ms, p.deadline - bridge.now()),
                  state.config.limits.header_count,
                )
              {
                Error(cause) ->
                  fail_reason(without, group, error.ConnectionFailed(cause))
                Ok(connected) -> {
                  let _ = process.monitor(connected)
                  State(..without, connections: [
                    Connection(connected, connection.origin, Connecting, 0),
                    ..without.connections
                  ])
                }
              }
          }
        }
      }
    }
  }
}

// A readiness refusal precedes gun:request. It discards only an unused socket;
// the original queued request keeps its budget, ownership and FIFO position.
fn checked(
  state: State,
  pid: process.Pid,
  worker: process.Pid,
  result: Result(Bool, error.Reason),
) -> State {
  case
    list.find(state.connections, fn(c) {
      c.pid == pid && c.status == Checking(worker)
    })
  {
    Error(_) -> state
    Ok(connection) ->
      case result {
        Ok(True) ->
          State(
            ..state,
            connections: list.map(state.connections, fn(c) {
              case c.pid == pid {
                True -> Connection(..c, status: Checked)
                False -> c
              }
            }),
          )
        Ok(False) | Error(_) -> {
          close_connection(connection)
          State(
            ..state,
            connections: list.filter(state.connections, fn(c) { c.pid != pid }),
          )
        }
      }
  }
}
