# Lifecycle observations through Sinal

HTTP Gun emits a small typed event through an application-owned Sinal forwarder. The existing pool and body owner supply the facts; Sinal supplies bounded asynchronous delivery. Observation is disabled by default. There is no HTTP Gun observation process, history store, timeline, callback registry or per-chunk event stream.

A REST service can measure admission time separately from response latency. A download or long poll can distinguish accepted response headers from HTTP termination. These measurements are best effort: use the ordinary HTTP Result and its typed evidence for correctness, cancellation and retry decisions.

## Application setup

The [ordinary public consumer](../examples/ordinary/src/http_gun_consumer.gleam) is executable and includes supervised setup, typed attachment, a live request and cleanup. Its dependencies include Sinal, Gleam Erlang and Gleam OTP. The essential configuration is:

```gleam
let target =
  forwarder.new(process.new_name("http-observations"))
  |> forwarder.with_capacity(64)
let assert Ok(supervisor) =
  static_supervisor.new(static_supervisor.OneForOne)
  |> static_supervisor.add(forwarder.supervised(target))
  |> static_supervisor.start

let settings = config.Config(..config.default(), observations: Some(target))
let assert Ok(shared) = http_gun.start(settings)
let assert Ok(correlation) = correlation.from_string(order_id)
let client = http_gun.with_correlation(shared, correlation)
let result = http_gun.send(client, req)
```

Import `http_gun/telemetry`, `sinal`, `sinal/correlation`, `sinal/forwarder`, `gleam/erlang/process`, `gleam/otp/static_supervisor` and `gleam/option.{Some}` alongside the normal HTTP imports. The application retains the supervisor for its service lifetime; completing one HTTP operation does not stop it. Use `http_gun.child(settings)` when supervising the client too. A restarted client needs the new Client capability; the same Sinal Forwarder capability survives its own restart.

Attach with `sinal.observe(telemetry.event(), handler)`; Sinal assigns the handler id. The handler receives `Timing(monotonic_ms)` and `Metadata(request_id, correlation, mode, milestone)`. It runs in the forwarder process. Detach through the returned Sinal Attachment when the application no longer wants it. Sinal attachments are VM-wide by event name; applications distinguish their work using correlation and must avoid installing duplicate handlers per request.

## Correlation and request identity

Every event's metadata carries two identities with different owners:

| Key | Gleam field | Owner | Meaning |
| --- | --- | --- | --- |
| `correlation` | `Option(sinal/correlation.Correlation)` | Caller | The unit of work, shared with every other gleam-dream package. Written by `correlation.field()`: a UTF-8 binary of 1 to 128 bytes, and the key is omitted when the client view carries none. |
| `request_id` | `telemetry.RequestId` | HTTP Gun | One observed invocation. All milestones of that invocation share it; invocations that reuse a correlation get distinct values. |

`http_gun.with_correlation(client, correlation)` is the only way to set the correlation. Pass the value the rest of the unit of work already uses: an order id or job id through `correlation.from_string`, a value received from an upstream package, or a fresh `correlation.unique()`. A handler then joins HTTP events with other packages' events by `metadata.correlation`, without a lookup table; an Erlang or Elixir handler reads the same `correlation` key. A correlation identifies one unit of work, so never use it as a metric tag.

The view is pure: it shares the existing client, starts no process and changes no HTTP policy, request matching or ownership. Stopping either view stops that client. A later `with_correlation` on a view replaces its correlation.

Only HTTP Gun creates a `RequestId`. It is opaque and compared by equality within one VM lifetime; Erlang handlers see a binary. It is not a durable identifier across VM restarts, and contains no application data, credentials or Gun references. Use it to group one invocation's milestones, not as a join key across packages.

## Exact milestones

| Milestone | Producer | Established fact |
| --- | --- | --- |
| `AdmissionEntered` | Pool | The pool received a validated invocation, before capture reservation/admission. Calls rejected before this point may have no events. |
| `AdmissionWaiting` | Pool | This invocation entered the finite pending queue, awaiting capacity or connection establishment. Emitted once, not on every recheck. |
| `AdmissionGranted` | Pool | An eligible live connection/stream was selected, or an offline exchange matched. It precedes body-owner startup and can therefore be followed by startup failure. |
| `GunCallReturned` | Body owner | The supported asynchronous Gun request call returned. This does **not** prove Gun processed the message, a socket write succeeded, the server received anything or an application effect happened. |
| `ResponseHeaders(status)` | Body owner | Final headers passed HTTP Gun's admission checks. Non-2xx statuses remain ordinary responses. |
| `HttpTerminated(outcome)` | Pool before handoff; body owner afterward | HTTP settled as Complete, LocallyCancelled, DeadlineExpired or Failed. Complete means HTTP EOF, not that the caller consumed or accepted the buffered data. |

All timestamps use monotonic VM-local milliseconds taken at emission. Same-producer delivery is FIFO; different producers can arrive out of lifecycle order. Compare source timestamps and milestone meaning, never arrival order. Millisecond ties are valid. Missing timestamps cannot support a duration measurement. Entered-to-granted includes capture reservation, queuing and connection work; it is not a pure socket-connect measurement. A request with no capacity wait need not emit AdmissionWaiting.

Cancellation races with completion. The owning actor's settled outcome wins; a later close cannot turn completed HTTP into cancellation or emit another normal terminal event. Forced actor/VM death, startup failures and dropped observations can leave incomplete event sequences. Observation is not a transaction or a delivery receipt. A missing GunCallReturned is never evidence of NotSubmitted. A body read-wait timeout emits no terminal event because HTTP remains open. Local cancellation says nothing about remote processing or rollback.

## Delivery and finite storage

HTTP Gun calls `forwarder.emit` directly. It never calls `sinal.emit` or the synchronous no-route fallback of `emit_routed` inside HTTP actors. There are no arbitrary consumer callbacks in these actors. Encoding still costs local CPU; fixed metadata keeps this work independent of HTTP body and header sizes.

The application chooses a positive Sinal capacity. It counts queued events plus the executing handler. Overflow rejects observations immediately; unavailable/restarting forwarders drop them. A blocked handler can stall that forwarder but cannot backpressure the HTTP request. Throwing handlers are isolated by the underlying telemetry dispatcher. An untrappable forwarder death can lose accepted events; restart establishes fresh admission counters and a direct destination for that incarnation. Delayed producers cannot send old events or drop notices into its replacement. Sinal coalesces drop notices rather than generating one mailbox message per rejected event.

HTTP Gun ignores observation delivery errors, preserving its ordinary outcome. Sinal's dropped event supplies aggregate rejection/unavailability diagnostics; its lost count is a best-effort snapshot. These reports can themselves be lost and provide neither durable totals nor per-request acknowledgements. Shutdown does not drain observations. There is no retained HTTP observation history. Applications own any additional sink, exporter, queue or history: forwarding every event into another unbounded mailbox would reintroduce the original problem.

Metadata contains no URLs, queries, headers, bodies, credentials or free-form failure terms. Fixed event names do not create per-request atoms. No per-chunk instrumentation is supplied.

## Modes and independent outcomes

Live mode emits `Live`; actual recording emits `Recorded`. Both can report GunCallReturned. Scripts and strict disk playback report `Offline` and never report a network call. They use the same admitted HTTP contract; offline matching, non-consuming mismatches and ordering are unchanged. Request ids and correlations are not fixture matching keys or stored request metadata.

HTTP termination, observation delivery and recording capture/persistence are separate outcomes. For example, HTTP can Complete while capture exceeds its budget and reports CaptureFailed. Always use the recording result for persistence, and never infer a published cassette from HTTP or telemetry completion.

## One Sinal source

Development resolves `sinal = { path = "../sinal" }`, also used by the current downstream. This is the canonical Sinal implementation; the current snapshot pins the Sinal commit recorded as `revision` in `dev/dependencies/sinal.json`. Sinal is not yet published on Hex, so the independent gate uses a hash-pinned source archive under `dev/dependencies`, materialized as that same sibling path inside a disposable workspace. It is a validation input, not an HTTP Gun fork or another runtime.

If the canonical checkout is present, the gate verifies its selected files match the snapshot. The downstream gate uses the actual selected Sinal checkout and performs the same check. The historical LLM archive is verified first, then its old Sinal copy is replaced in the temporary workspace by this selected source. Only one Sinal copy resolves in each build. Licenses, source revision and per-file hashes are retained. Replace this temporary packaging with an immutable released dependency when one exists; no publication is implied or performed here.

A standalone gate needs no sibling checkout. Ordinary manual development/builds need the selected Sinal beside HTTP Gun; to prepare an isolated checkout explicitly, run `python3 dev/sinal_source.py /path/to/workspace/sinal` into a new directory. Do not independently edit the snapshot or silently update it: apply generic corrections in Sinal, validate them, and regenerate the archive with matching provenance.
