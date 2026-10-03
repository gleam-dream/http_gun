//// Emits `[http_gun, lifecycle]` events for one request. The pool creates a
//// context when a request arrives; the pool and the body owner emit through
//// it. Emission never fails and never blocks on a handler.

import gleam/option.{type Option, None, Some}
import http_gun/error
import http_gun/internal/bridge
import http_gun/telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/forwarder

pub opaque type Emitter {
  Routed(event: sinal.Event(telemetry.Timing, telemetry.Metadata))
  Forwarded(
    target: forwarder.Forwarder,
    event: sinal.Event(telemetry.Timing, telemetry.Metadata),
  )
}

pub opaque type Context {
  Context(
    emitter: Emitter,
    request_id: telemetry.RequestId,
    correlation: Option(Correlation),
    mode: telemetry.Mode,
  )
}

pub fn prepare(target: Option(forwarder.Forwarder)) -> Emitter {
  case target {
    None -> Routed(telemetry.event())
    Some(target) -> Forwarded(target, telemetry.event())
  }
}

pub fn begin(
  emitter: Emitter,
  correlation: Option(Correlation),
  mode: telemetry.Mode,
) -> Context {
  let context = Context(emitter, telemetry.new_request_id(), correlation, mode)
  emit(context, telemetry.AdmissionEntered)
  context
}

pub fn emit(context: Context, milestone: telemetry.Milestone) -> Nil {
  let timing = telemetry.Timing(bridge.now())
  let metadata =
    telemetry.Metadata(
      context.request_id,
      context.correlation,
      context.mode,
      milestone,
    )
  case context.emitter {
    Routed(event) -> sinal.emit(event, timing, metadata)
    Forwarded(target, event) -> {
      let _ = forwarder.emit(target, event, timing, metadata)
      Nil
    }
  }
}

pub fn termination(outcome: Result(a, error.Failure)) -> telemetry.Milestone {
  telemetry.HttpTerminated(case outcome {
    Ok(_) -> telemetry.Complete
    Error(failure) ->
      case error.reason(failure) {
        error.Cancelled | error.Closed -> telemetry.LocallyCancelled
        error.DeadlineExceeded -> telemetry.DeadlineExpired
        _ -> telemetry.Failed
      }
  })
}
