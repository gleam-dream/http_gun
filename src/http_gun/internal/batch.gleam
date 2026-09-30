import gleam/erlang/process
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/otp/actor
import gleam/result
import http_gun/error.{type Failure, Failure, MayHaveBeenSent, NotSubmitted}
import http_gun/internal/call

type Worker {
  Worker(pid: process.Pid, monitor: process.Monitor, index: Int)
}

type Message(value) {
  Begin(process.Subject(Result(List(Result(value, Failure)), Failure)))
  Done(process.Pid, Int, Result(value, Failure))
  Lost(process.Down)
}

type State(input, value) {
  State(
    subject: process.Subject(Message(value)),
    owner: process.Pid,
    pending: List(#(Int, input)),
    workers: List(Worker),
    results: List(#(Int, Result(value, Failure))),
    reply: Option(
      process.Subject(Result(List(Result(value, Failure)), Failure)),
    ),
    concurrency: Int,
    run: fn(input) -> Result(value, Failure),
  )
}

pub fn run(
  inputs: List(input),
  concurrency: Int,
  perform: fn(input) -> Result(value, Failure),
) -> Result(List(Result(value, Failure)), Failure) {
  case concurrency > 0 && concurrency <= 1024 && list.length(inputs) <= 10_000 {
    False ->
      Error(Failure(
        error.InvalidRequest(
          "batch requires 1..1024 workers and at most 10000 inputs",
        ),
        NotSubmitted,
      ))
    True -> {
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
              subject,
              owner,
              list.index_map(inputs, fn(item, i) { #(i, item) }),
              [],
              [],
              None,
              concurrency,
              perform,
            ))
            |> actor.selecting(selector)
            |> actor.returning(subject),
          )
        })
        |> actor.on_message(handle)
        |> actor.start
      use started <- result.try(
        started
        |> result.map_error(fn(_) { Failure(error.ClientClosed, NotSubmitted) }),
      )
      process.unlink(started.pid)
      call.run(started.data, Begin)
    }
  }
}

fn handle(
  state: State(input, value),
  message: Message(value),
) -> actor.Next(State(input, value), Message(value)) {
  case message {
    Begin(reply) -> advance(State(..state, reply: Some(reply)))
    Done(pid, index, value) -> {
      list.each(state.workers, fn(worker) {
        case worker.pid == pid {
          True -> process.demonitor_process(worker.monitor)
          False -> Nil
        }
      })
      advance(
        State(
          ..state,
          workers: list.filter(state.workers, fn(w) { w.pid != pid }),
          results: [#(index, value), ..state.results],
        ),
      )
    }
    Lost(process.ProcessDown(pid: pid, ..)) ->
      case pid == state.owner {
        True -> {
          list.each(state.workers, fn(w) { process.kill(w.pid) })
          actor.stop()
        }
        False ->
          case list.find(state.workers, fn(w) { w.pid == pid }) {
            Error(Nil) -> actor.continue(state)
            Ok(worker) ->
              advance(
                State(
                  ..state,
                  workers: list.filter(state.workers, fn(w) { w.pid != pid }),
                  results: [
                    #(
                      worker.index,
                      Error(Failure(error.RequestFailed, MayHaveBeenSent)),
                    ),
                    ..state.results
                  ],
                ),
              )
          }
      }
    Lost(process.PortDown(..)) -> actor.continue(state)
  }
}

fn advance(
  state: State(input, value),
) -> actor.Next(State(input, value), Message(value)) {
  let running = list.length(state.workers)
  case state.pending, state.workers, state.reply {
    [], [], Some(reply) -> {
      process.send(
        reply,
        Ok(
          state.results
          |> list.sort(fn(a, b) { int.compare(a.0, b.0) })
          |> list.map(fn(pair) { pair.1 }),
        ),
      )
      actor.stop()
    }
    [#(index, input), ..rest], workers, _ if running < state.concurrency -> {
      let pid =
        process.spawn_unlinked(fn() {
          process.send(
            state.subject,
            Done(process.self(), index, state.run(input)),
          )
        })
      let worker = Worker(pid, process.monitor(pid), index)
      advance(State(..state, pending: rest, workers: [worker, ..workers]))
    }
    _, _, _ -> actor.continue(state)
  }
}
