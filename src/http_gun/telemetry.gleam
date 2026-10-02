//// Best-effort HTTP lifecycle observations delivered by an explicit Sinal forwarder.
//// No handlers run in HTTP owners. No history, URLs, headers or body data are kept.
//// Missing events are not submission evidence or permission to retry.
////
//// Every event's metadata carries two identities:
////
//// - `correlation`: the caller's `sinal/correlation.Correlation`, set with
////   `http_gun.with_correlation` and written through `correlation.field()`.
////   The key is omitted when the client view carries none. Use it to join
////   HTTP events with the events of other packages working on the same unit.
//// - `request_id`: an opaque `RequestId` that HTTP Gun assigns to each
////   observed invocation. Invocations that share a correlation still get
////   distinct request ids, so a handler can group one invocation's milestones.

import gleam/dynamic
import gleam/dynamic/decode
import gleam/erlang/reference
import gleam/option.{type Option, None, Some}
import gleam/string
import http_gun/error
import http_gun/internal/bridge
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields
import sinal/forwarder

/// The identity HTTP Gun assigns to one observed invocation. Only HTTP Gun
/// creates it. Equality is meaningful within one VM lifetime; it is not a
/// durable identifier, a credential or a network reference. Erlang handlers
/// see it as a binary under the `request_id` key.
pub opaque type RequestId {
  RequestId(value: String)
}

fn new_request_id() -> RequestId {
  RequestId(string.inspect(reference.new()))
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
    request_id: RequestId,
    correlation: Option(Correlation),
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
    fields.record({
      use monotonic_ms <- fields.parameter
      Timing(monotonic_ms:)
    })
    |> fields.and(fields.int("monotonic_ms"), fn(t: Timing) { t.monotonic_ms })
    |> fields.build
  let metadata =
    fields.record({
      use request_id <- fields.parameter
      use correlation <- fields.parameter
      use mode <- fields.parameter
      use milestone <- fields.parameter
      Metadata(request_id:, correlation:, mode:, milestone:)
    })
    |> fields.and(request_id_field(), fn(m: Metadata) { m.request_id })
    |> fields.and(correlation.field(), fn(m) { m.correlation })
    |> fields.and(
      fields.enum("mode", [Live, Recorded, Offline], mode_name),
      fn(m) { m.mode },
    )
    |> fields.and(milestone_field(), fn(m) { m.milestone })
    |> fields.build
  sinal.event(["http_gun", "lifecycle"], at, metadata)
}

fn request_id_field() -> fields.Fields(RequestId) {
  fields.field(
    "request_id",
    fn(id: RequestId) { dynamic.string(id.value) },
    decode.string |> decode.map(RequestId),
  )
}

fn milestone_field() -> fields.Fields(Milestone) {
  fields.field(
    "milestone",
    fn(value) {
      let #(name, number) = encode_milestone(value)
      dynamic.array([dynamic.string(name), dynamic.int(number)])
    },
    {
      use name <- decode.field(0, decode.string)
      use number <- decode.field(1, decode.int)
      case parse_milestone(#(name, number)) {
        Ok(milestone) -> decode.success(milestone)
        Error(Nil) -> decode.failure(AdmissionEntered, "HTTP milestone")
      }
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
  Context(
    emitter: Emitter,
    request_id: RequestId,
    correlation: Option(Correlation),
    mode: Mode,
  )
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
  correlation: Option(Correlation),
  mode: Mode,
) -> Option(Context) {
  case emitter {
    None -> None
    Some(emitter) -> {
      let context = Some(Context(emitter, new_request_id(), correlation, mode))
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
