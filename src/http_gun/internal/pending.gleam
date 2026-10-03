// Pool-owned FIFO lanes. Every live entry has exactly one lane and owner index.
// Indexed links allow expiry and caller death to remove an entry without scans
// or accumulating tombstones behind a blocked request.
import gleam/dict.{type Dict}
import gleam/erlang/process
import gleam/erlang/reference.{type Reference}
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{type Option, None, Some}
import http_gun/destination
import http_gun/error.{type Failure}
import http_gun/internal/lifecycle
import http_gun/internal/owner
import http_gun/internal/recorder
import http_gun/internal/settings
import http_gun/internal/token

pub type Origin {
  Origin(host: String, port: Int, tls: Bool)
}

pub type Group {
  ForOrigin(Origin)
  Session
}

/// One request waiting for admission. The request is held in a closure, so
/// a crash report of the pool prints a function reference instead of its
/// headers and body.
pub type Pending {
  Pending(
    id: Reference,
    owner: process.Pid,
    request: fn() -> request.Request(BitArray),
    origin: Origin,
    reply: fn(Result(response.Response(owner.Body), Failure)) -> Nil,
    deadline: Option(Int),
    pool_until: Int,
    idle: settings.Bound,
    policies: List(destination.Policy),
    monitor: process.Monitor,
    timer: process.Timer,
    reservation: Option(process.Pid),
    capture: Option(recorder.Capture),
    cancellation: Option(token.Token),
    cancel_monitor: Option(process.Monitor),
    observation: lifecycle.Context,
  )
}

type Entry {
  Entry(
    group: Group,
    value: Pending,
    previous: Option(Reference),
    next: Option(Reference),
  )
}

type Ends {
  Ends(first: Reference, last: Reference)
}

pub opaque type Queue {
  Queue(
    entries: Dict(Reference, Entry),
    groups: Dict(Group, Ends),
    owners: Dict(process.Pid, Reference),
    waiting: Int,
    order: List(Group),
    cancellations: Dict(process.Monitor, Reference),
  )
}

pub fn new() -> Queue {
  Queue(dict.new(), dict.new(), dict.new(), 0, [], dict.new())
}

pub fn waiting(queue: Queue) -> Int {
  queue.waiting
}

pub fn groups(queue: Queue) -> List(Group) {
  queue.order
}

// Only origins that make progress yield their turn. Blocked origins retain
// their position without blocking eligible origins later in the list.
pub fn rotate(queue: Queue, group: Group) -> Queue {
  case queue.order {
    [] | [_] -> queue
    _ ->
      case has_group(queue, group) {
        False -> queue
        True ->
          Queue(
            ..queue,
            order: list.append(list.filter(queue.order, fn(g) { g != group }), [
              group,
            ]),
          )
      }
  }
}

pub fn has_group(queue: Queue, group: Group) -> Bool {
  dict.has_key(queue.groups, group)
}

pub fn values(queue: Queue) -> List(Pending) {
  dict.fold(queue.entries, [], fn(acc, _, entry) { [entry.value, ..acc] })
}

pub fn first(queue: Queue, group: Group) -> Result(Pending, Nil) {
  case dict.get(queue.groups, group) {
    Error(_) -> Error(Nil)
    Ok(ends) -> {
      let assert Ok(entry) = dict.get(queue.entries, ends.first)
      Ok(entry.value)
    }
  }
}

fn counted(p: Pending) -> Int {
  case p.reservation {
    None -> 1
    Some(_) -> 0
  }
}

// Public open waits for its reply, so a caller has at most one pending open.
pub fn push(queue: Queue, group: Group, p: Pending) -> Queue {
  let #(entries, ends, previous) = case dict.get(queue.groups, group) {
    Error(_) -> #(queue.entries, Ends(p.id, p.id), None)
    Ok(ends) -> {
      let assert Ok(last) = dict.get(queue.entries, ends.last)
      #(
        dict.insert(queue.entries, ends.last, Entry(..last, next: Some(p.id))),
        Ends(..ends, last: p.id),
        Some(ends.last),
      )
    }
  }
  Queue(
    dict.insert(entries, p.id, Entry(group, p, previous, None)),
    dict.insert(queue.groups, group, ends),
    dict.insert(queue.owners, p.owner, p.id),
    queue.waiting + counted(p),
    case previous {
      None -> list.append(queue.order, [group])
      Some(_) -> queue.order
    },
    case p.cancel_monitor {
      None -> queue.cancellations
      Some(monitor) -> dict.insert(queue.cancellations, monitor, p.id)
    },
  )
}

pub fn replace(queue: Queue, p: Pending) -> Queue {
  let assert Ok(entry) = dict.get(queue.entries, p.id)
  Queue(
    ..queue,
    entries: dict.insert(queue.entries, p.id, Entry(..entry, value: p)),
    waiting: queue.waiting - counted(entry.value) + counted(p),
  )
}

pub fn remove(queue: Queue, id: Reference) -> #(Option(Pending), Queue) {
  case dict.get(queue.entries, id) {
    Error(_) -> #(None, queue)
    Ok(entry) -> {
      let entries = case entry.previous {
        None -> queue.entries
        Some(id) -> {
          let assert Ok(previous) = dict.get(queue.entries, id)
          dict.insert(queue.entries, id, Entry(..previous, next: entry.next))
        }
      }
      let entries = case entry.next {
        None -> entries
        Some(id) -> {
          let assert Ok(next) = dict.get(entries, id)
          dict.insert(entries, id, Entry(..next, previous: entry.previous))
        }
      }
      let assert Ok(ends) = dict.get(queue.groups, entry.group)
      let groups = case entry.previous, entry.next {
        None, None -> dict.delete(queue.groups, entry.group)
        None, Some(first) ->
          dict.insert(queue.groups, entry.group, Ends(..ends, first: first))
        Some(last), None ->
          dict.insert(queue.groups, entry.group, Ends(..ends, last: last))
        Some(_), Some(_) -> queue.groups
      }
      #(
        Some(entry.value),
        Queue(
          dict.delete(entries, id),
          groups,
          dict.delete(queue.owners, entry.value.owner),
          queue.waiting - counted(entry.value),
          case entry.previous, entry.next {
            None, None -> list.filter(queue.order, fn(g) { g != entry.group })
            _, _ -> queue.order
          },
          case entry.value.cancel_monitor {
            None -> queue.cancellations
            Some(monitor) -> dict.delete(queue.cancellations, monitor)
          },
        ),
      )
    }
  }
}

pub fn remove_owner(
  queue: Queue,
  owner: process.Pid,
) -> #(Option(Pending), Queue) {
  case dict.get(queue.owners, owner) {
    Error(_) -> #(None, queue)
    Ok(id) -> remove(queue, id)
  }
}

pub fn remove_cancellation(
  queue: Queue,
  monitor: process.Monitor,
) -> #(Option(Pending), Queue) {
  case dict.get(queue.cancellations, monitor) {
    Error(_) -> #(None, queue)
    Ok(id) -> remove(queue, id)
  }
}
