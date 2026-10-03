//// Emits `[http_gun, lifecycle]` events for one request. The pool creates a
//// context when a request arrives; the pool and the body owner emit through
//// it. Emission never fails and never blocks on a handler.

import gleam/option.{type Option}
import http_gun/error
import http_gun/internal/bridge
import http_gun/internal/settings
import http_gun/telemetry
import sinal
import sinal/correlation.{type Correlation}
import sinal/forwarder

pub opaque type Emitter {
  Routed(
    event: sinal.Event(telemetry.Timing, telemetry.Metadata),
    client: Option(String),
  )
  Forwarded(
    target: forwarder.Forwarder,
    event: sinal.Event(telemetry.Timing, telemetry.Metadata),
    client: Option(String),
  )
  Silenced
}

pub opaque type Context {
  Context(
    emitter: Emitter,
    request_id: telemetry.RequestId,
    correlation: Option(Correlation),
    mode: telemetry.Mode,
  )
}

pub fn prepare(
  observations: settings.Observations,
  client: Option(String),
) -> Emitter {
  case observations {
    settings.Emit -> Routed(telemetry.event(), client)
    settings.Forward(target) -> Forwarded(target, telemetry.event(), client)
    settings.Silent -> Silenced
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
  case context.emitter {
    Routed(event, client) ->
      sinal.emit(event, timing(), metadata(context, client, milestone))
    Forwarded(target, event, client) -> {
      let _ =
        forwarder.emit(
          target,
          event,
          timing(),
          metadata(context, client, milestone),
        )
      Nil
    }
    Silenced -> Nil
  }
}

fn timing() -> telemetry.Timing {
  telemetry.Timing(bridge.now())
}

fn metadata(
  context: Context,
  client: Option(String),
  milestone: telemetry.Milestone,
) -> telemetry.Metadata {
  telemetry.Metadata(
    request_id: context.request_id,
    correlation: context.correlation,
    client:,
    mode: context.mode,
    milestone:,
  )
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
