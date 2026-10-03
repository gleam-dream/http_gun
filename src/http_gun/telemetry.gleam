//// Describes the `[http_gun, lifecycle]` event that every client emits as a
//// request moves through admission, submission, headers and termination.
////
//// Events are best effort: a missing event is not submission evidence or
//// permission to retry. They carry no URL, header, query or body.
////
//// HTTP Gun emits with `sinal.emit`, so the application decides where
//// handlers run. Route the prefix to a forwarder once at startup to keep
//// handlers out of HTTP Gun's pool and body processes:
////
//// ```gleam
//// forwarder.route(["http_gun"], my_forwarder)
//// let attachment = sinal.observe(telemetry.event(), fn(timing, metadata) {
////   record(metadata.request_id, metadata.milestone, timing.monotonic_ms)
//// })
//// ```
////
//// Without a route, handlers run synchronously in the pool and body
//// processes, and a slow handler slows requests. `config.with_observations`
//// sends one client's events to a forwarder directly instead.
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
import gleam/option.{type Option}
import gleam/string
import sinal
import sinal/correlation.{type Correlation}
import sinal/fields

/// The identity HTTP Gun assigns to one observed invocation. Equality is meaningful within one VM lifetime; it is not a
/// durable identifier, a credential or a network reference. Erlang handlers
/// see it as a binary under the `request_id` key.
pub opaque type RequestId {
  RequestId(value: String)
}

/// A fresh identity, unique within this VM. HTTP Gun creates one per
/// request; a test double that emits HTTP Gun events can create its own.
pub fn new_request_id() -> RequestId {
  RequestId(string.inspect(reference.new()))
}

/// The identity as text, for logs.
pub fn request_id_to_string(id: RequestId) -> String {
  id.value
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

/// The typed `[http_gun, lifecycle]` event. Attach handlers through Sinal in
/// the application. Handler arrival order across the pool and body processes
/// is not a request ordering guarantee: compare `monotonic_ms` and the
/// milestone's meaning.
pub fn event() -> sinal.Event(Timing, Metadata) {
  let at = {
    use monotonic_ms <- fields.include(fields.int("monotonic_ms"), get: fn(t) {
      t.monotonic_ms
    })
    fields.success(Timing(monotonic_ms:))
  }
  let metadata = {
    use request_id <- fields.include(request_id_field(), get: fn(m) {
      m.request_id
    })
    use correlation <- fields.include(correlation.field(), get: fn(m) {
      m.correlation
    })
    use mode <- fields.include(
      fields.enum("mode", [Live, Recorded, Offline], mode_name),
      get: fn(m) { m.mode },
    )
    use milestone <- fields.include(milestone_field(), get: fn(m) {
      m.milestone
    })
    fields.success(Metadata(request_id:, correlation:, mode:, milestone:))
  }
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
