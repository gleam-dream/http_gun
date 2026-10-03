//// The pool actor behind every `http_gun.Client`: bounded admission, FIFO
//// lanes per origin, connection lifecycle, playback and recording modes, and
//// draining on stop. A `Client` holds the actor's subject and the view
//// settings of one handle; the actor owns the configuration.

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
import http_gun/destination
import http_gun/error.{type Failure, MaybeSent, NotSent}
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/lifecycle
import http_gun/internal/observation as obs
import http_gun/internal/owner
import http_gun/internal/pending.{type Origin, type Pending, Origin, Pending}
import http_gun/internal/preparation
import http_gun/internal/recorder
import http_gun/internal/resolution
import http_gun/internal/script
import http_gun/internal/settings.{type Settings}
import http_gun/internal/token
import http_gun/redaction
import http_gun/telemetry
import sinal/correlation.{type Correlation}

/// Per-handle settings. Every field is optional and falls back to the
/// client's configuration.
pub type View {
  View(
    timeout: Option(settings.Bound),
    deadline: Option(Int),
    idle: Option(settings.Bound),
    token: Option(token.Token),
    body_limit: Option(#(Int, Bool)),
    policies: List(destination.Policy),
    correlation: Option(Correlation),
  )
}

pub opaque type Client {
  Client(subject: process.Subject(Message), view: View)
}

const no_view = View(None, None, None, None, None, [], None)

type Status {
  Resolving
  Connecting
  Ready(settings.Negotiated, Int)
  Checking(process.Pid)
  Checked
}

type Connection {
  Connection(
    pid: process.Pid,
    origin: Origin,
    status: Status,
    used: Int,
    addresses: List(destination.Address),
    idle_ref: Option(reference.Reference),
    connect_until: Int,
  )
}

type Owned {
  Owned(
    pid: process.Pid,
    body: owner.Body,
    connection: Option(process.Pid),
    released: Bool,
  )
}

pub type Mode {
  Record(recorder.Recording)
  Live
  Playback(
    remaining: List(script.Exchange),
    position: Int,
    matching: script.Matching,
  )
}

type Phase {
  Running
  Draining(replies: List(process.Subject(Result(Nil, Failure))))
}

type State {
  State(
    self: process.Subject(Message),
    mode: Mode,
    config: Settings,
    connections: List(Connection),
    pending: pending.Queue,
    owners: Dict(process.Pid, Owned),
    emitter: lifecycle.Emitter,
    phase: Phase,
  )
}

/// What a caller sends to open one request.
type Invocation {
  Invocation(
    request: fn() -> request.Request(BitArray),
    origin: Origin,
    entered: Int,
    view: View,
    owner: process.Pid,
  )
}

pub type Opened {
  Opened(
    response: response.Response(owner.Body),
    body_limit: #(Int, Bool),
    redaction: redaction.Redaction,
  )
}

pub opaque type Message {
  Resolved(process.Pid, Result(resolution.Resolved, error.Reason))
  CheckedConnection(process.Pid, process.Pid, Result(Bool, error.Reason))
  Inspect(process.Subject(Result(#(Int, Int, Int), Failure)))
  Configuration(process.Subject(Result(Settings, Failure)))
  Open(Invocation, process.Subject(Result(Opened, Failure)))
  Stop(process.Subject(Result(Nil, Failure)))
  ShutdownExpired
  Wire(bridge.Event)
  Lost(process.Down)
  Expire(reference.Reference)
  ConnectExpired(process.Pid)
  IdleConnection(process.Pid, reference.Reference)
  Release(process.Pid, Option(process.Pid), Bool)
  OwnerClosed(process.Pid)
}

pub fn named(name: process.Name(Message)) -> Client {
  Client(process.named_subject(name), no_view)
}

pub fn stats(client: Client) -> Result(#(Int, Int, Int), Failure) {
  call.run(client.subject, Inspect)
}

pub fn settings(client: Client) -> Result(Settings, Failure) {
  call.run(client.subject, Configuration)
}

pub fn view(client: Client) -> View {
  client.view
}

pub fn with_view(client: Client, view: View) -> Client {
  Client(..client, view:)
}

pub fn open(
  client: Client,
  req: request.Request(BitArray),
) -> Result(Opened, Failure) {
  let view = client.view
  let entered = bridge.now()
  use Nil <- result.try(case view.token {
    Some(token) ->
      case token.is_cancelled(token) {
        True -> Error(error.new(error.Cancelled, NotSent))
        False -> Ok(Nil)
      }
    None -> Ok(Nil)
  })
  use Nil <- result.try(case view.deadline {
    Some(at) if at <= entered ->
      Error(error.new(error.DeadlineExceeded, NotSent))
    _ -> Ok(Nil)
  })
  use Nil <- result.try(case view.body_limit {
    Some(#(limit, _)) if limit < 0 ->
      Error(error.new(error.InvalidRequest(error.InvalidBodyLimit), NotSent))
    _ -> Ok(Nil)
  })
  let req = case req.path {
    "" -> request.Request(..req, path: "/")
    _ -> req
  }
  use origin <- result.try(validate_target(req))
  // Nothing was sent when the client is not registered or already dead; a
  // client that exits while handling the call may have submitted it.
  call.with_failures(
    client.subject,
    Open(Invocation(fn() { req }, origin, entered, view, process.self()), _),
    not_running: error.new(error.ClientClosed, NotSent),
    lost: error.new(error.ClientClosed, MaybeSent),
  )
}

/// Stop a client, letting open bodies finish within the shutdown timeout.
pub fn stop(client: Client) -> Nil {
  let _ = call.run(client.subject, Stop)
  Nil
}

pub fn start(config: Settings, mode: Mode) -> actor.StartResult(Client) {
  start_with(config, mode, None)
}

pub fn start_named(
  config: Settings,
  name: process.Name(Message),
) -> actor.StartResult(Client) {
  start_with(config, Live, Some(name))
}

fn start_with(
  config: Settings,
  mode: Mode,
  name: Option(process.Name(Message)),
) -> actor.StartResult(Client) {
  use Nil <- result.try(
    case mode {
      Live | Record(_) -> bridge.start()
      Playback(..) -> Ok(Nil)
    }
    |> result.map_error(fn(_) {
      actor.InitFailed("Gun application could not start")
    }),
  )
  let builder =
    actor.new_with_initialiser(1000, fn(public) {
      // Timers, workers and body owners reply on a private subject, so a
      // restarted named client never receives its predecessor's messages.
      let private = process.new_subject()
      let selector =
        process.new_selector()
        |> process.select(public)
        |> process.select(private)
        |> process.select_monitors(Lost)
        |> process.select_other(fn(value) { Wire(bridge.decode(value)) })
      Ok(
        actor.initialised(State(
          self: private,
          mode:,
          config:,
          connections: [],
          pending: pending.new(),
          owners: dict.new(),
          emitter: lifecycle.prepare(config.observations, config.label),
          phase: Running,
        ))
        |> actor.selecting(selector)
        |> actor.returning(Client(public, no_view)),
      )
    })
    |> actor.on_message(handle)
  case name {
    Some(name) -> actor.named(builder, name)
    None -> builder
  }
  |> actor.start
}

fn origin(req: request.Request(a)) -> Origin {
  let tls = req.scheme == http.Https
  Origin(
    bridge.unbracket(string.lowercase(req.host)),
    case req.port {
      Some(port) -> port
      None ->
        case tls {
          True -> 443
          False -> 80
        }
    },
    tls,
  )
}

fn validate_target(req: request.Request(BitArray)) -> Result(Origin, Failure) {
  let invalid = fn(problem) {
    Error(error.new(error.InvalidRequest(problem), NotSent))
  }
  let origin = origin(req)
  let method_ok =
    http.parse_method(http.method_to_string(req.method)) |> result.is_ok
  case bit_array.bit_size(req.body) % 8 == 0, method_ok {
    False, _ -> invalid(error.BodyNotBytes)
    True, False -> invalid(error.InvalidMethod)
    True, True ->
      case
        origin.host != ""
        && origin.port > 0
        && origin.port <= 65_535
        && safe_target(origin.host)
      {
        False -> invalid(error.InvalidOrigin)
        True ->
          case
            safe_target(option.unwrap(req.query, ""))
            && safe_target(req.path)
            && string.starts_with(req.path, "/")
          {
            False -> invalid(error.InvalidTarget)
            True ->
              case
                list.all(req.headers, fn(h) {
                  h.0 == string.lowercase(h.0)
                  && http.parse_method(h.0) |> result.is_ok
                  && !string.contains(h.1, "\r")
                  && !string.contains(h.1, "\n")
                  && !string.contains(h.1, "\u{0}")
                })
              {
                False -> invalid(error.InvalidHeader)
                True -> Ok(origin)
              }
          }
      }
  }
}

fn validate_size(
  req: request.Request(BitArray),
  limits: settings.Limits,
) -> Result(Nil, Failure) {
  case bit_array.byte_size(req.body) <= limits.request_body_bytes {
    False ->
      Error(error.new(
        error.LimitExceeded(
          error.RequestBodyBytes,
          limits.request_body_bytes,
          bit_array.byte_size(req.body),
        ),
        NotSent,
      ))
    True ->
      owner.check_headers(req.headers, limits, owner.RequestHeaders)
      |> result.map_error(error.new(_, NotSent))
  }
}

fn safe_target(value: String) -> Bool {
  !list.any([" ", "\r", "\n", "\t", "\u{0}"], fn(char) {
    string.contains(value, char)
  })
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
        Ok(#(
          list.length(state.connections),
          dict.size(state.owners),
          pending.waiting(state.pending),
        )),
      )
      actor.continue(state)
    }
    Configuration(reply) -> {
      process.send(reply, Ok(state.config))
      actor.continue(state)
    }
    Stop(reply) -> begin_stop(state, reply)
    ShutdownExpired ->
      case state.phase {
        Draining(replies) -> finish_stop(state, replies)
        Running -> actor.continue(state)
      }
    Open(invocation, reply) ->
      case state.phase {
        Draining(_) -> {
          process.send(reply, Error(error.new(error.ClientClosed, NotSent)))
          actor.continue(state)
        }
        Running -> open_request(state, invocation, reply)
      }
    Expire(id) -> {
      let #(expired, queue) = pending.remove(state.pending, id)
      case expired {
        None -> actor.continue(state)
        Some(p) -> {
          let now = bridge.now()
          let reason = case p.deadline {
            Some(at) if at <= now -> error.DeadlineExceeded
            _ -> error.PoolTimeout
          }
          reject(p, reason)
          actor.continue(
            dispatch(discard_reservation(State(..state, pending: queue), p)),
          )
        }
      }
    }
    ConnectExpired(pid) ->
      case list.find(state.connections, fn(c) { c.pid == pid }) {
        Ok(Connection(status: Resolving, ..) as c)
        | Ok(Connection(status: Connecting, ..) as c) -> {
          close_connection(c)
          let state =
            State(
              ..state,
              connections: list.filter(state.connections, fn(c) { c.pid != pid }),
            )
          actor.continue(
            dispatch(fail_reason(
              state,
              pending.ForOrigin(c.origin),
              error.ConnectTimeout,
            )),
          )
        }
        _ -> actor.continue(state)
      }
    IdleConnection(pid, id) ->
      case list.find(state.connections, fn(c) { c.pid == pid }) {
        Ok(c) if c.idle_ref == Some(id) && c.used == 0 -> {
          close_connection(c)
          actor.continue(
            State(
              ..state,
              connections: list.filter(state.connections, fn(c) { c.pid != pid }),
            ),
          )
        }
        _ -> actor.continue(state)
      }
    Release(pid, connection, clean) ->
      release_body(state, pid, connection, clean)
    // A closed body no longer counts as open, before its process exits.
    OwnerClosed(pid) ->
      case dict.get(state.owners, pid) {
        Ok(Owned(released: True, ..)) ->
          actor.continue(
            State(..state, owners: dict.delete(state.owners, pid))
            |> dispatch_if_running,
          )
        _ -> actor.continue(state)
      }
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
        state.config.protocol == settings.RequireHttp2
        && protocol != settings.H2
      {
        True -> handle(state, Wire(bridge.Down(pid, error.UnexpectedProtocol)))
        False -> {
          // Wait for initial SETTINGS before admitting H2 application streams.
          let capacity = case protocol {
            settings.H1 -> 1
            _ -> 0
          }
          let connections =
            list.map(state.connections, fn(c) {
              case c.pid == pid {
                True ->
                  Connection(..c, status: case protocol {
                    settings.H1 -> Checked
                    settings.H2 | settings.Offline -> Ready(protocol, capacity)
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
                  settings.H2,
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

fn begin_stop(
  state: State,
  reply: process.Subject(Result(Nil, Failure)),
) -> actor.Next(State, Message) {
  case state.phase {
    Draining(replies) ->
      actor.continue(State(..state, phase: Draining([reply, ..replies])))
    Running -> {
      list.each(pending.values(state.pending), fn(p) {
        reject(p, error.ClientClosed)
      })
      let state = State(..state, pending: pending.new())
      case active(state) == 0 || state.config.shutdown_timeout == 0 {
        True -> finish_stop(state, [reply])
        False -> {
          let _ =
            process.send_after(
              state.self,
              state.config.shutdown_timeout,
              ShutdownExpired,
            )
          actor.continue(State(..state, phase: Draining([reply])))
        }
      }
    }
  }
}

fn finish_stop(
  state: State,
  replies: List(process.Subject(Result(Nil, Failure))),
) -> actor.Next(State, Message) {
  dict.each(state.owners, fn(_, o) {
    case o.released {
      True -> Nil
      False -> owner.close(o.body)
    }
  })
  list.each(state.connections, close_connection)
  list.each(replies, process.send(_, Ok(Nil)))
  actor.stop()
}

fn dispatch_if_running(state: State) -> State {
  case state.phase {
    Running -> dispatch(state)
    Draining(_) -> state
  }
}

fn active(state: State) -> Int {
  dict.fold(state.owners, 0, fn(count, _, o) {
    case o.released {
      True -> count
      False -> count + 1
    }
  })
}

fn reject(p: Pending, reason: error.Reason) -> Nil {
  reject_with(p, error.new(reason, NotSent))
}

fn reject_with(p: Pending, failure: Failure) -> Nil {
  lifecycle.emit(p.observation, lifecycle.termination(Error(failure)))
  case p.capture {
    Some(cap) -> recorder.write(cap, obs.Failed(failure), fn(_) { Nil })
    None -> Nil
  }
  let _ = process.cancel_timer(p.timer)
  case p.cancel_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  process.demonitor_process(p.monitor)
  p.reply(Error(failure))
}

// A deferred head blocks only its origin. Playback uses one session lane.
type Admission {
  Taken(State)
  Deferred(State, Pending)
}

fn group(state: State, p: Pending) -> pending.Group {
  case state.mode {
    Playback(..) -> pending.Session
    Live | Record(_) -> pending.ForOrigin(p.origin)
  }
}

fn dispatch(state: State) -> State {
  let state = list.fold(pending.groups(state.pending), state, dispatch_group)
  // Readiness is usable only by this admission pass. If body capacity or a
  // cancelled waiter prevents launch, do not cache an old liveness observation.
  let connections =
    list.map(state.connections, fn(c) {
      case c.status {
        Checked -> Connection(..c, status: Ready(settings.H1, 1))
        _ -> c
      }
    })
  State(..state, connections: list.map(connections, idle_timer(state, _)))
}

// An established connection that carries nothing gets one idle timer; a
// connection in use loses it.
fn idle_timer(state: State, c: Connection) -> Connection {
  case c.status, c.used, c.idle_ref {
    Ready(..), 0, None -> {
      let id = reference.new()
      let _ =
        process.send_after(
          state.self,
          state.config.connection_idle_timeout,
          IdleConnection(c.pid, id),
        )
      Connection(..c, idle_ref: Some(id))
    }
    _, used, Some(_) if used > 0 -> Connection(..c, idle_ref: None)
    _, _, _ -> c
  }
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

fn policies(state: State, p: Pending) -> List(destination.Policy) {
  [state.config.destination, ..p.policies]
}

fn admit_live(state: State, p: Pending) -> Admission {
  case
    resolution.admit(
      policies(state, p),
      p.origin.host,
      p.origin.port,
      p.origin.tls,
      [],
    )
  {
    Error(reason) -> {
      reject(p, reason)
      Taken(state)
    }
    Ok(Nil) -> admit_connection(state, p)
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
    Ok(connection) ->
      // A narrower view must admit every address the connection resolved.
      case
        resolution.admit(
          policies(state, p),
          p.origin.host,
          p.origin.port,
          p.origin.tls,
          connection.addresses,
        )
      {
        Error(reason) -> {
          reject(p, reason)
          Taken(state)
        }
        Ok(Nil) -> admit_eligible(state, p, connection)
      }
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
          let self = state.self
          let connect_until = bridge.now() + state.config.connect_timeout
          let pid =
            resolution.start(
              process.self(),
              policies(state, p),
              state.config.resolver,
              p.origin.host,
              p.origin.port,
              p.origin.tls,
              connect_until,
              fn(pid, result) { process.send(self, Resolved(pid, result)) },
            )
          let _ = process.monitor(pid)
          let _ =
            process.send_after(
              state.self,
              state.config.connect_timeout,
              ConnectExpired(pid),
            )
          // The request that opens a connection may wait for it to connect.
          let _ = process.cancel_timer(p.timer)
          let until = case p.deadline {
            Some(at) -> int.min(at, int.max(p.pool_until, connect_until + 1))
            None -> int.max(p.pool_until, connect_until + 1)
          }
          let timer =
            process.send_after(
              state.self,
              int.max(0, until - bridge.now()),
              Expire(p.id),
            )
          Deferred(
            State(..state, connections: [
              Connection(pid, p.origin, Resolving, 0, [], None, connect_until),
              ..state.connections
            ]),
            Pending(..p, reservation: Some(pid), timer:),
          )
        }
      }
    }
  }
}

fn admit_eligible(
  state: State,
  p: Pending,
  connection: Connection,
) -> Admission {
  case connection.status {
    Ready(settings.H1, _) -> {
      let self = state.self
      let pid = connection.pid
      let worker =
        preparation.start(
          process.self(),
          p.pool_until,
          error.ConnectionFailed(error.UnknownTransport),
          fn() { Ok(bridge.reusable(pid)) },
          fn(worker, result) {
            process.send(self, CheckedConnection(pid, worker, result))
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
    _ -> Taken(launch(state, p, connection))
  }
}

fn timing(p: Pending) -> owner.Timing {
  owner.Timing(p.deadline, p.idle)
}

fn launch(state: State, p: Pending, connection: Connection) -> State {
  lifecycle.emit(p.observation, telemetry.AdmissionGranted)
  let protocol = case connection.status {
    Ready(protocol, _) -> protocol
    Resolving | Connecting | Checking(_) | Checked -> settings.H1
  }
  // This callback crosses a process boundary. Capture only its destinations,
  // never the pool state (which also contains every queued request).
  let self = state.self
  let connection_pid = connection.pid
  let release = fn(clean) {
    process.send(self, Release(process.self(), Some(connection_pid), clean))
  }
  case
    owner.start(
      process.self(),
      owner.Live(connection.pid, protocol),
      p.request,
      p.owner,
      timing(p),
      state.config.limits,
      p.reply,
      release,
      fn() { process.send(self, OwnerClosed(process.self())) },
      p.capture,
      p.cancellation,
      p.observation,
    )
  {
    Error(_) -> {
      reject_with(
        p,
        error.new(error.RequestFailed(error.UnknownTransport), MaybeSent),
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
      settle(p)
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
              Connection(
                ..c,
                used: c.used + 1,
                idle_ref: None,
                status: case c.status {
                  Checked -> Ready(settings.H1, 1)
                  other -> other
                },
              )
            False -> c
          }
        }),
      )
    }
  }
}

// The body owner now answers the caller; stop watching for its death here.
fn settle(p: Pending) -> Nil {
  case p.cancel_monitor {
    Some(monitor) -> process.demonitor_process(monitor)
    None -> Nil
  }
  process.demonitor_process(p.monitor)
  let _ = process.cancel_timer(p.timer)
  Nil
}

fn admit(state: State, p: Pending) -> Admission {
  let cancelled = case p.cancellation {
    None -> False
    Some(token) -> token.is_cancelled(token)
  }
  let expired = case p.deadline {
    Some(at) -> bridge.now() >= at
    None -> False
  }
  case cancelled, expired {
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
        >= state.config.limits.open_bodies
      {
        True -> Deferred(state, p)
        False ->
          case state.mode {
            Live | Record(_) -> admit_live(state, p)
            Playback(exchanges, position, matching) ->
              Taken(admit_playback(state, p, exchanges, position, matching))
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
  exchanges: List(script.Exchange),
  position: Int,
  matching: script.Matching,
) -> State {
  case exchanges {
    [] -> {
      reject(p, error.PlaybackExhausted)
      state
    }
    [exchange, ..rest] ->
      case
        script.matches(
          matching,
          state.config.redaction,
          exchange.request,
          p.request(),
        )
      {
        False -> {
          reject(p, error.PlaybackMismatch(position))
          state
        }
        True -> {
          lifecycle.emit(p.observation, telemetry.AdmissionGranted)
          let self = state.self
          let release = fn(clean) {
            process.send(self, Release(process.self(), None, clean))
          }
          case
            owner.start(
              process.self(),
              owner.Script(exchange.reply),
              p.request,
              p.owner,
              timing(p),
              state.config.limits,
              p.reply,
              release,
              fn() { process.send(self, OwnerClosed(process.self())) },
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
              settle(p)
              State(
                ..state,
                mode: Playback(rest, position + 1, matching),
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
  state: State,
  req: request.Request(BitArray),
) -> Result(Option(recorder.Capture), Failure) {
  case state.mode {
    Live | Playback(..) -> Ok(None)
    Record(recording) ->
      case
        recorder.reserve(
          recording,
          redaction.request(state.config.redaction, req),
        )
      {
        Ok(cap) -> Ok(Some(cap))
        Error(recorder.SessionClosed) ->
          Error(error.new(error.RecordingClosed, NotSent))
        Error(_) -> Ok(None)
      }
  }
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

fn effective_deadline(config: Settings, invocation: Invocation) -> Option(Int) {
  let view = invocation.view
  case view.deadline, view.timeout {
    Some(at), Some(timeout) ->
      case settings.until(timeout, invocation.entered) {
        Some(until) -> Some(int.min(at, until))
        None -> Some(at)
      }
    Some(at), None -> Some(at)
    None, Some(timeout) -> settings.until(timeout, invocation.entered)
    None, None -> settings.until(config.request_timeout, invocation.entered)
  }
}

fn open_request(
  state: State,
  invocation: Invocation,
  reply: process.Subject(Result(Opened, Failure)),
) -> actor.Next(State, Message) {
  let view = invocation.view
  let observation =
    lifecycle.begin(state.emitter, view.correlation, case state.mode {
      Live -> telemetry.Live
      Record(_) -> telemetry.Recorded
      Playback(..) -> telemetry.Offline
    })
  let body_limit =
    option.unwrap(view.body_limit, #(
      state.config.limits.response_body_bytes,
      False,
    ))
  // The pool or the body owner answers the caller once, adding the
  // collection policy `send` needs. Capture only those values: this callback
  // crosses process boundaries.
  let redact = state.config.redaction
  let relay = fn(outcome) {
    process.send(
      reply,
      result.map(outcome, fn(response) { Opened(response, body_limit, redact) }),
    )
  }
  let req = invocation.request()
  let early = case
    state.config.view_destination_required && view.policies == []
  {
    True -> Error(error.new(error.ViewDestinationRequired, NotSent))
    False ->
      case validate_size(req, state.config.limits) {
        Error(failure) -> Error(failure)
        Ok(Nil) -> reserve_capture(state, req)
      }
  }
  case early {
    Error(failure) -> {
      lifecycle.emit(observation, lifecycle.termination(Error(failure)))
      process.send(reply, Error(failure))
      actor.continue(state)
    }
    Ok(capture) -> {
      let deadline = effective_deadline(state.config, invocation)
      let now = bridge.now()
      let pool_until = now + state.config.pool_timeout
      let first = case deadline {
        Some(at) -> int.min(at, pool_until)
        None -> pool_until
      }
      let id = reference.new()
      let timer =
        process.send_after(state.self, int.max(0, first - now), Expire(id))
      let p =
        Pending(
          id:,
          owner: invocation.owner,
          request: invocation.request,
          origin: invocation.origin,
          reply: relay,
          deadline:,
          pool_until:,
          idle: option.unwrap(view.idle, state.config.idle_timeout),
          policies: view.policies,
          monitor: process.monitor(invocation.owner),
          timer:,
          reservation: None,
          capture:,
          cancellation: view.token,
          cancel_monitor: option.map(view.token, token.monitor),
          observation:,
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
            && pending.waiting(next.pending)
            >= state.config.limits.queued_requests
          {
            True -> {
              reject(p, error.AdmissionFull)
              actor.continue(next)
            }
            False -> {
              lifecycle.emit(p.observation, telemetry.AdmissionWaiting)
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
                Ready(settings.H1, _), False -> {
                  bridge.close(c.pid)
                  Error(Nil)
                }
                _, _ -> Ok(Connection(..c, used: int.max(0, c.used - 1)))
              }
          }
        })
      let state =
        State(
          ..state,
          connections: connections,
          owners: dict.insert(state.owners, pid, Owned(..owner, released: True)),
        )
      case state.phase {
        Draining(replies) ->
          case active(state) {
            0 -> finish_stop(state, replies)
            _ -> actor.continue(state)
          }
        Running -> actor.continue(dispatch(state))
      }
    }
  }
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
          fail_reason(state, pending.ForOrigin(connection.origin), case cause {
            error.TransportTimeout -> error.ConnectTimeout
            _ -> error.ConnectionFailed(cause)
          })
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
  let next = State(..next, owners: dict.delete(next.owners, pid))
  case next.phase {
    Draining(replies) ->
      case active(next) {
        0 -> finish_stop(next, replies)
        _ -> actor.continue(next)
      }
    Running -> actor.continue(dispatch(next))
  }
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
        Error(error.DeadlineExceeded), _ ->
          fail_reason(without, group, error.ConnectTimeout)
        Error(reason), _ -> fail_reason(without, group, reason)
        Ok(target), Ok(p) -> {
          let remaining = case p.deadline {
            Some(at) -> at - bridge.now()
            None -> state.config.connect_timeout
          }
          case remaining <= 0 {
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
                  int.max(
                    1,
                    int.min(connection.connect_until - bridge.now(), remaining),
                  ),
                  case state.config.idle_timeout {
                    settings.Within(ms) -> bridge.SendWithin(ms)
                    settings.Unbounded -> bridge.SendUnbounded
                  },
                  state.config.limits.header_count,
                )
              {
                Error(cause) ->
                  fail_reason(without, group, error.ConnectionFailed(cause))
                Ok(connected) -> {
                  let _ = process.monitor(connected)
                  // The connect timer follows the connection to its new pid.
                  let _ =
                    process.send_after(
                      state.self,
                      int.max(0, connection.connect_until - bridge.now()),
                      ConnectExpired(connected),
                    )
                  State(..without, connections: [
                    Connection(
                      connected,
                      connection.origin,
                      Connecting,
                      0,
                      target.addresses,
                      None,
                      connection.connect_until,
                    ),
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

pub fn with_correlation(client: Client, correlation: Correlation) -> Client {
  Client(..client, view: View(..client.view, correlation: Some(correlation)))
}
