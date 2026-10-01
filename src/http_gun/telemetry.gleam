//// Best-effort HTTP lifecycle observations delivered by an explicit Sinal forwarder.
//// No handlers run in HTTP owners. No history, URLs, headers or body data are kept.
//// Missing events are not submission evidence or permission to retry.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/atom
import gleam/erlang/reference
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import http_gun/error
import http_gun/internal/bridge
import sinal
import sinal/fields
import sinal/forwarder

/// An opaque VM-local identifier. Equality is meaningful within this VM lifetime.
pub opaque type Id {
  Id(value: String)
}

/// Create an identity for correlating a call or a group of calls. HTTP Gun also
/// creates a distinct request_id for every observed invocation, even when a
/// correlation is reused. Neither identity is a credential or a network reference.
pub fn new_id() -> Id {
  Id(string.inspect(reference.new()))
}

/// Scripts and disk playback both report Offline; neither claims network activity.
pub type Mode {
  Live
  Recorded
  Offline
}

/// HTTP termination, independent of observation delivery and capture persistence.
/// Complete means HTTP EOF, not that the application consumed or accepted the body.
pub type Outcome {
  Complete
  LocallyCancelled
  DeadlineExpired
  Failed
}

pub type Milestone {
  /// The pool received a validated invocation, before admission/capture reservation.
  AdmissionEntered
  /// The invocation entered the finite queue, waiting for capacity or connection setup.
  AdmissionWaiting
  /// The pool selected an eligible connection/stream or matched an offline exchange.
  AdmissionGranted
  /// Gun's asynchronous request API returned. No transport processing, successful
  /// socket write, remote receipt or application effect is established by this fact.
  GunCallReturned
  /// Final response headers passed HTTP Gun's admission checks.
  ResponseHeaders(status: Int)
  /// The HTTP owner settled its outcome. Abrupt actor/VM death can omit this event.
  HttpTerminated(Outcome)
}

pub type Timing {
  Timing(monotonic_ms: Int)
}

pub type Metadata {
  Metadata(
    request_id: Id,
    correlation: Option(Id),
    mode: Mode,
    milestone: Milestone,
  )
}

/// The typed [http_gun, lifecycle] event. Attach handlers through Sinal in the
/// application. A blocked handler stalls the configured forwarder; overflow
/// drops observations. Handler arrival order across pool/body producers is not
/// a request ordering guarantee. Compare source timestamps and milestone meaning.
pub fn event() -> sinal.Event(Timing, Metadata) {
  let at =
    fields.imap(fields.int(atom.create("monotonic_ms")), Timing, fn(t) {
      t.monotonic_ms
    })
  let id = id_field("request_id")
  let assert Ok(correlation) = fields.optional(id_field("correlation"))
  let assert Ok(ids) = fields.pair(id, correlation)
  let mode = enum_field("mode", mode_name, parse_mode)
  let stage =
    fields.field(
      atom.create("milestone"),
      fn(value) {
        let #(name, number) = encode_milestone(value)
        Ok(dynamic.array([dynamic.string(name), dynamic.int(number)]))
      },
      fn(raw) {
        use pair <- result.try(
          decode.run(raw, {
            use name <- decode.field(0, decode.string)
            use value <- decode.field(1, decode.int)
            decode.success(#(name, value))
          })
          |> result.map_error(fn(_) {
            fields.FieldDecodeError("invalid HTTP milestone")
          }),
        )
        parse_milestone(pair)
        |> result.map_error(fn(_) {
          fields.FieldDecodeError("invalid HTTP milestone")
        })
      },
    )
  let assert Ok(description) = fields.pair(mode, stage)
  let assert Ok(all) = fields.pair(ids, description)
  let metadata =
    fields.imap(
      all,
      fn(value) { Metadata(value.0.0, value.0.1, value.1.0, value.1.1) },
      fn(value) {
        #(
          #(value.request_id, value.correlation),
          #(value.mode, value.milestone),
        )
      },
    )
  let assert Ok(event) =
    sinal.event(
      [atom.create("http_gun"), atom.create("lifecycle")],
      at,
      metadata,
    )
  event
}

fn id_field(name: String) -> fields.Fields(Id) {
  fields.imap(fields.string(atom.create(name)), Id, fn(id) { id.value })
}

fn enum_field(
  name: String,
  encode: fn(a) -> String,
  parse: fn(String) -> Result(a, Nil),
) -> fields.Fields(a) {
  fields.field(
    atom.create(name),
    fn(value) { Ok(dynamic.string(encode(value))) },
    fn(raw) {
      use text <- result.try(
        decode.run(raw, decode.string)
        |> result.map_error(fn(_) {
          fields.FieldDecodeError("invalid HTTP mode")
        }),
      )
      parse(text)
      |> result.map_error(fn(_) { fields.FieldDecodeError("invalid HTTP mode") })
    },
  )
}

fn mode_name(mode: Mode) -> String {
  case mode {
    Live -> "live"
    Recorded -> "recorded"
    Offline -> "offline"
  }
}

fn parse_mode(name: String) -> Result(Mode, Nil) {
  case name {
    "live" -> Ok(Live)
    "recorded" -> Ok(Recorded)
    "offline" -> Ok(Offline)
    _ -> Error(Nil)
  }
}

fn encode_milestone(stage: Milestone) -> #(String, Int) {
  case stage {
    AdmissionEntered -> #("admission_entered", 0)
    AdmissionWaiting -> #("admission_waiting", 0)
    AdmissionGranted -> #("admission_granted", 0)
    GunCallReturned -> #("gun_call_returned", 0)
    ResponseHeaders(status) -> #("response_headers", status)
    HttpTerminated(Complete) -> #("complete", 0)
    HttpTerminated(LocallyCancelled) -> #("locally_cancelled", 0)
    HttpTerminated(DeadlineExpired) -> #("deadline_expired", 0)
    HttpTerminated(Failed) -> #("failed", 0)
  }
}

fn parse_milestone(value: #(String, Int)) -> Result(Milestone, Nil) {
  case value {
    #("admission_entered", 0) -> Ok(AdmissionEntered)
    #("admission_waiting", 0) -> Ok(AdmissionWaiting)
    #("admission_granted", 0) -> Ok(AdmissionGranted)
    #("gun_call_returned", 0) -> Ok(GunCallReturned)
    #("response_headers", status) if status >= 100 && status <= 999 ->
      Ok(ResponseHeaders(status))
    #("complete", 0) -> Ok(HttpTerminated(Complete))
    #("locally_cancelled", 0) -> Ok(HttpTerminated(LocallyCancelled))
    #("deadline_expired", 0) -> Ok(HttpTerminated(DeadlineExpired))
    #("failed", 0) -> Ok(HttpTerminated(Failed))
    _ -> Error(Nil)
  }
}

@internal
pub opaque type Emitter {
  Emitter(target: forwarder.Forwarder, event: sinal.Event(Timing, Metadata))
}

@internal
pub opaque type Context {
  Context(emitter: Emitter, request_id: Id, correlation: Option(Id), mode: Mode)
}

@internal
pub fn prepare(target: Option(forwarder.Forwarder)) -> Option(Emitter) {
  case target {
    None -> None
    Some(target) -> Some(Emitter(target, event()))
  }
}

@internal
pub fn begin(
  emitter: Option(Emitter),
  correlation: Option(Id),
  mode: Mode,
) -> Option(Context) {
  case emitter {
    None -> None
    Some(emitter) -> {
      let context = Some(Context(emitter, new_id(), correlation, mode))
      emit(context, AdmissionEntered)
      context
    }
  }
}

@internal
pub fn emit(context: Option(Context), milestone: Milestone) -> Nil {
  case context {
    None -> Nil
    Some(ctx) -> {
      let _ =
        forwarder.emit(
          ctx.emitter.target,
          ctx.emitter.event,
          Timing(bridge.now()),
          Metadata(ctx.request_id, ctx.correlation, ctx.mode, milestone),
        )
      Nil
    }
  }
}

@internal
pub fn termination(outcome: Result(a, error.Failure)) -> Milestone {
  HttpTerminated(case outcome {
    Ok(_) -> Complete
    Error(error.Failure(error.Cancelled, _))
    | Error(error.Failure(error.Closed, _)) -> LocallyCancelled
    Error(error.Failure(error.DeadlineExceeded, _)) -> DeadlineExpired
    Error(_) -> Failed
  })
}
