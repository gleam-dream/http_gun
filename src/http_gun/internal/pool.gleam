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
import http_gun/config
import http_gun/error.{type Failure, Failure, NotSubmitted}
import http_gun/fixture
import http_gun/internal/bridge
import http_gun/internal/call
import http_gun/internal/observation as obs
import http_gun/internal/pending.{type Origin, type Pending, Origin, Pending}
import http_gun/recording

pub type Stats {
  Stats(connections: Int, bodies: Int, waiting: Int)
}

pub opaque type Client {
  Client(subject: process.Subject(Message), config: config.Config)
}

type Status {
  Connecting
  Ready(config.Negotiated, Int)
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
  )
}

type Message {
  Inspect(process.Subject(Result(Stats, Failure)))
  Open(
    request.Request(BitArray),
    Origin,
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
  let req = case req.path {
    "" -> request.Request(..req, path: "/")
    _ -> req
  }
  use origin <- result.try(validate(req, client.config.limits))
  let deadline = bridge.now() + client.config.deadline_ms
  call.with_failure(
    client.subject,
    Open(req, origin, process.self(), deadline, _),
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
      ))
      |> actor.selecting(selector)
      |> actor.returning(Client(subject, settings)),
    )
  })
  |> actor.on_message(handle)
  |> actor.start
}

fn origin(req: request.Request(a)) -> Origin {
  let tls = req.scheme == http.Https
  Origin(string.lowercase(req.host), option_port(req, tls), tls)
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
      list.each(state.connections, fn(c) { bridge.close(c.pid) })
      process.send(reply, Ok(Nil))
      actor.stop()
    }
    Open(req, origin, owner, deadline, reply) ->
      open_request(state, req, origin, owner, deadline, reply)
    Expire(id) -> {
      let #(expired, queue) = pending.remove(state.pending, id)
      case expired {
        None -> actor.continue(state)
        Some(p) -> {
          reject(p, error.DeadlineExceeded)
          actor.continue(dispatch(State(..state, pending: queue)))
        }
      }
    }
    Release(pid, connection, clean) ->
      release_body(state, pid, connection, clean)
    Lost(process.PortDown(..)) -> actor.continue(state)
    Lost(process.ProcessDown(pid: pid, ..)) -> process_lost(state, pid)
    Wire(bridge.Up(pid, protocol)) ->
      case
        state.config.protocol == config.RequireHttp2 && protocol != config.H2
      {
        True -> handle(state, Wire(bridge.Down(pid)))
        False -> {
          // Wait for initial SETTINGS before admitting H2 application streams.
          let capacity = case protocol {
            config.H1 -> 1
            _ -> 0
          }
          let connections =
            list.map(state.connections, fn(c) {
              case c.pid == pid {
                True -> Connection(..c, status: Ready(protocol, capacity))
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
    Wire(bridge.Down(pid)) ->
      actor.continue(dispatch(connection_lost(state, pid)))
    Wire(_) -> actor.continue(state)
  }
}

fn reject(p: Pending, reason: error.Reason) -> Nil {
  reject_with(p, Failure(reason, NotSubmitted))
}

fn reject_with(p: Pending, failure: Failure) -> Nil {
  case p.capture {
    Some(cap) -> recording.write(cap, obs.Failed(failure), fn(_) { Nil })
    None -> Nil
  }
  let _ = process.cancel_timer(p.timer)
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
  list.fold(pending.groups(state.pending), state, dispatch_group)
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
            State(..next, pending: pending.rotate(queue, group)),
            group,
          )
        }
      }
  }
}

fn admit_live(state: State, p: Pending) -> Admission {
  let eligible =
    list.find(state.connections, fn(c) {
      c.origin == p.origin
      && case c.status {
        Connecting -> False
        Ready(_, capacity) -> c.used < capacity
      }
    })
  case eligible {
    Ok(connection) -> Taken(launch(state, p, connection))
    Error(Nil) -> {
      let state = make_room(state, p.origin)
      let same = list.filter(state.connections, fn(c) { c.origin == p.origin })
      case
        list.length(state.connections) < state.config.limits.connections
        && list.length(same) < state.config.limits.per_origin
        && !list.any(same, fn(c) { c.status == Connecting })
      {
        False -> Deferred(state, p)
        True ->
          case
            bridge.open(
              p.origin.host,
              p.origin.port,
              p.origin.tls,
              state.config.protocol,
              state.config.trust,
              int.min(state.config.connect_ms, p.deadline - bridge.now()),
              state.config.limits.header_count,
            )
          {
            Error(Nil) -> {
              reject(p, error.ConnectionFailed)
              Taken(state)
            }
            Ok(pid) -> {
              let _ = process.monitor(pid)
              Deferred(
                State(..state, connections: [
                  Connection(pid, p.origin, Connecting, 0),
                  ..state.connections
                ]),
                Pending(..p, reservation: Some(pid)),
              )
            }
          }
      }
    }
  }
}

fn launch(state: State, p: Pending, connection: Connection) -> State {
  let protocol = case connection.status {
    Ready(protocol, _) -> protocol
    Connecting -> config.H1
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
    )
  {
    Error(_) -> {
      reject_with(p, Failure(error.RequestFailed, error.MayHaveBeenSent))
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
            True -> Connection(..c, used: c.used + 1)
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
            error.LimitExceeded("request", limits.request_bytes),
            NotSubmitted,
          ))
        True ->
          body.check_headers(req.headers, limits)
          |> result.map_error(fn(f) { Failure(f.reason, NotSubmitted) })
          |> result.map(fn(_) { origin })
      }
  }
}

fn admit(state: State, p: Pending) -> Admission {
  case bridge.now() >= p.deadline {
    True -> {
      reject(p, error.DeadlineExceeded)
      Taken(state)
    }
    False ->
      case dict.size(state.owners) >= state.config.limits.active {
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
            )
          {
            Error(_) -> {
              reject(p, error.RequestFailed)
              state
            }
            Ok(started) -> {
              process.unlink(started.pid)
              let _ = process.monitor(started.pid)
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
            error.CaptureFailed("recording is finalized"),
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
          && c.status != Connecting
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
  owner: process.Pid,
  deadline: Int,
  reply: process.Subject(Result(response.Response(body.Body), Failure)),
) -> actor.Next(State, Message) {
  case reserve_capture(state.mode, req) {
    Error(failure) -> {
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
            False ->
              actor.continue(
                State(..next, pending: pending.push(next.pending, group, p)),
              )
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

fn fail_group(state: State, group: pending.Group) -> State {
  case pending.first(state.pending, group) {
    Error(_) -> state
    Ok(p) -> {
      reject(p, error.ConnectionFailed)
      let #(_, queue) = pending.remove(state.pending, p.id)
      fail_group(State(..state, pending: queue), group)
    }
  }
}

fn connection_lost(state: State, pid: process.Pid) -> State {
  case list.find(state.connections, fn(c) { c.pid == pid }) {
    Error(_) -> state
    Ok(connection) -> {
      bridge.close(pid)
      let state =
        State(
          ..state,
          connections: list.filter(state.connections, fn(c) { c.pid != pid }),
        )
      case connection.status {
        Connecting -> fail_group(state, pending.ForOrigin(connection.origin))
        Ready(_, _) -> state
      }
    }
  }
}

fn process_lost(state: State, pid: process.Pid) -> actor.Next(State, Message) {
  let state = connection_lost(state, pid)
  let #(cancelled, queue) = pending.remove_owner(state.pending, pid)
  case cancelled {
    Some(p) -> reject(p, error.Closed)
    None -> Nil
  }
  let state = State(..state, pending: queue)
  let next = case dict.get(state.owners, pid) {
    Ok(Owned(connection: Some(connection), released: False, ..)) ->
      connection_lost(state, connection)
    _ -> state
  }
  actor.continue(dispatch(State(..next, owners: dict.delete(next.owners, pid))))
}
