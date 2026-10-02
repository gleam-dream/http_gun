# HTTP Gun

An independent HTTP client for Gleam on Erlang/OTP, using released Gun for transport. Public values, pool admission, body ownership, batches, cassette matching and recording coordination are implemented in Gleam.

Requests use `gleam/http/request.Request(BitArray)`. Responses preserve status codes, duplicate headers, arbitrary bytes and trailers. Non-2xx statuses are data. There are no automatic retries, redirects or decompression.

## Ordinary requests

```gleam
import gleam/http/request
import http_gun
import http_gun/config

pub fn main() {
  // Explicit opt-in for this local development server.
  let settings = config.default() |> config.allow_loopback
  let assert Ok(client) = http_gun.start(settings)
  let assert Ok(req) = request.to("http://localhost:8080/data")
  let result = http_gun.send(client, request.set_body(req, <<>>))
  let _ = http_gun.stop(client)
  result
}
```

`send` returns `Result(Buffered, Failure)`. `Buffered` contains a standard `Response(BitArray)`, separate trailers and the observed `H1`, `H2` or `Offline` protocol. It collects the same stream used by streaming callers, enforcing the configured collection limit and closing on failure. An oversized body fails with `LimitExceeded(CollectedBodyBytes, ..)` and `MayHaveBeenSent`, without the status. `send_with_options` accepts a per-request `request_options.Collect(limit, overflow)`: `Fail` keeps that failure, while `Truncate` returns the status, headers and the first `limit` bytes with `Buffered.truncated` set, so the caller can still act on the status.

## Streaming and batches

```gleam
// Returning after one chunk closes locally, even if the callback raises.
let first = http_gun.try_with_response(
  client,
  req,
  fn(failure) { failure },
  fn(response) { body.next(response.body, 1000) },
)

// At most ten workers. Results retain the input order, including failures.
let results = http_gun.batch(client, requests, 10)
```

Import `http_gun/body` for `next`, `close`, `collect` and `protocol`. `next` yields `Chunk(BitArray)` or `End(trailers)`. `try_with_response` maps opening failures with the supplied function and returns the callback's Result directly. The original `with_response` preserves arbitrary callback return types. Both close on return or exception.

Advanced callers can use `open` to obtain `Response(Body)` and explicitly `close` its opaque body. The process that opens the response owns consumption. Copies share one cursor. A read while another is pending returns `ReadConflict`; a different consumer otherwise receives `WrongOwner`. Handles do not transfer ownership. Close is idempotent and can be requested by another holder.

A read-wait timeout returns `ReadTimeout` while preserving the stream and outstanding demand. The overall request deadline covers admission, DNS, connection setup, sending and consumption; expiry terminates unfinished HTTP work. Completed data remains readable until close or owner death. Early close, scope exit, consumer death and client shutdown release the lease once. Local cancellation says nothing about whether the server continued processing the request.

Per-request controls use `request_options.Options`: an optional opaque monotonic `Deadline` and scoped cancellation `Token`. Use `send_with_options`, `open_with_options` or the corresponding scoped variants. The effective deadline is the earlier of the client ceiling and the supplied deadline. A shared token can cancel associated requests before headers or during consumption; scope exit and creator death also cancel them. See [usage examples](docs/API_ERGONOMICS.md) and the [maintained asynchronous feed recipe](examples/async/README.md), including supervised startup and cancellation before headers.

## Configuration and lifecycle

`config.default()` is a pure record. Compose records before calling `start`:

```gleam
let defaults = config.default()
let settings = config.Config(
  ..defaults,
  protocol: config.PreferHttp2,
  deadline_ms: 60_000,
  limits: config.Limits(..defaults.limits, collect_bytes: 1_048_576),
)
```

`http_gun.request_ceiling_ms(client)` reads that capability’s immutable startup ceiling, even after stop. It does not check liveness or extend a request budget.

Defaults: public destinations only, H1, verified system TLS trust, 30-second request ceiling, five-second connection budget, 16 connections, four per origin, 100 streams per H2 connection, 128 active body handles and 128 waiting requests. Byte defaults and their precise scope are in [BOUNDS.md](BOUNDS.md).

`CustomCa(path)` replaces system trust with a CA file while retaining hostname verification. `Anchors(certificates)` accepts a nonempty list of DER-encoded CA certificates directly in memory, with the same verification and no temporary files. Neither configures client identity or mTLS. Empty/non-byte anchor values fail configuration validation; OTP handles certificate decoding during TLS and may ignore invalid DER entries (an invalid-only trust set cannot authenticate the server). Each client owns its pool; different trust or transport policies never share connections. `PreferHttp2` negotiates H2 over TLS and otherwise uses H1. `RequireHttp2` requires H2 over TLS; explicit plaintext HTTP uses H2 prior knowledge. Eligible connections are reused before another is opened. H1 reuse performs a bounded Gun readiness check before submission; closing/dead connections are discarded while the queued request retains its original deadline. Request/response `Connection: close` tokens retire an H1 connection after completion. A peer can still close after the check; no submitted request is replayed. Idle sockets yield global slots to other origins. H1 leases are exclusive; H2 leases respect configured and observed peer capacity.

`http_gun.child(settings)` supplies a standard Gleam OTP supervisor child specification. The client process is linked to its starter; `stop` cancels active work and closes connections. A supervisor restart creates a new client capability; old handles remain closed. Gun application startup uses OTP. The library does not stop shared Gun/SSL applications when one client stops.

`Failure(reason, evidence)` distinguishes invalid input, admission, connection, stream, ownership, deadline, limit and fixture failures. Limits carry typed categories and observed sizes; transport and filesystem errors carry bounded causes. `HeaderLimitReached` identifies a Gun response header/trailer limit without inventing a measured size; malformed input that Gun reports only as a close or crash retains its coarser failure category. `error.describe` omits free-form details and request content. The [API guide](docs/API_ERGONOMICS.md#typed-diagnostics-and-fixture-format) explains error matching. `NotSubmitted` describes failures known to precede submission. `MayHaveBeenSent` is conservative, including uncertain client/process races. Neither value establishes remote execution. Status interpretation and retry decisions belong to the caller. `snapshot` returns finite connection/body/waiting counters without request history.

## Destination policy and pinned DNS

`config.destination` is a pure `destination.Policy`. Defaults allow public
addresses and refuse loopback, private and reserved addresses. Opt into
`allow_loopback` for local services, or call `config.allow_loopback(config)`,
which sets only that flag; opt into `allow_private` for private networks;
reserved ranges and cloud metadata addresses remain forbidden. `allow_public`
can also be disabled. Optional `allowed_hosts: Some(["issuer.example"])`
restricts exact, case-insensitive host names, **not ports**. It intersects the
address policy. IPv6 entries use bare addresses without URL brackets.

A new hostname connection resolves A and AAAA once, within the request budget.
Every returned address must pass policy, including IPv4-mapped/NAT64 forms; a
mixed public/forbidden answer refuses the whole origin. Gun connects to the
first checked address, with no second DNS resolution or address fallback. TLS
verifies the original hostname. IP literals are checked directly, omit SNI,
and verify their certificate's IP SAN. Plain HTTP remains available. Requests
keep their original HTTP authority, including IPv6 brackets.

DNS answers are trusted for **one connection's lifetime only**. Reuse stays
inside one immutable client policy and origin; opening a replacement connection
resolves again. Start a new client and stop the old one to change policy—changing
a previously supplied configuration value does not change a running client.
`DestinationRejected` and `ResolutionFailed` carry `NotSubmitted` and no raw
DNS/transport detail. No request is retried automatically.

Tests can set `resolver: Some(fn(host, remaining_ms) { ... })`, returning one
complete `Result(List(destination.Address), Nil)` answer per new connection.
HTTP Gun isolates the resolver, bounds its lifetime, checks every address and
fails closed on empty/invalid/failed answers. Treat a custom resolver as trusted
application code: it must return the complete answer, and owns any external
resources it creates. The default uses OTP `inet:getaddrs/3` for both families.
Scripts and strict playback never resolve or apply a network policy; recording
uses the live policy and records refusals as well as completed HTTP exchanges.

See [BOUNDS.md](BOUNDS.md#destination-policy) for precise DNS, send and parser
boundaries. Gun/Cowlib remain unmodified; status reason phrases are discarded by
Gun and cannot be validated by this client. Delivered headers are validated.

## Lifecycle observations

Set `config.Config(..defaults, observations: Some(target))` with an application-supervised `sinal/forwarder.Forwarder`. HTTP Gun emits typed admission, local Gun-call return, headers and HTTP termination through `http_gun/telemetry.event()`. `http_gun.with_correlation(client, correlation)` makes a pure view of the shared client whose events carry the caller's `sinal/correlation.Correlation` under the ecosystem-wide `correlation` key; HTTP Gun's own per-invocation identity is `request_id`. Delivery is bounded and best effort; slow observers cause drops, never HTTP backpressure. No URLs, headers, bodies or per-chunk events are emitted. Use HTTP failures for submission evidence, never missing telemetry. See the [contract and public example](docs/OBSERVATIONS.md).

## One consumer, explicit startup mode

Every mode supplies the same `Client`:

- Live: `http_gun.start(settings)`.
- Script: `testing.start(settings, exchanges)` using `fixture.Exchange` values.
- Playback: `cassette.load(path, max_bytes)`, then `cassette.playback(tape, settings)`.
- Recording: `cassette.record(settings, path, recording.default())`, returning a `Recorded` value with `client` and `recording` fields.

The [separate consumer](examples/ordinary/src/http_gun_consumer.gleam) executes the same buffered, scoped and batch operations in live, recording and playback modes. The [isolated LLM example](examples/llm/src/http_gun_llm_consumer.gleam) uses public LLM Wire encoding/reduction above HTTP Gun, with synthetic offline data and no provider credentials. Its small text-event adapter is an application example, not a general SSE implementation.

Playback is strictly offline and sequential. Repeated identical requests may have different successive responses. A mismatch reports the expected position without consuming it; missing, corrupt, incompatible and exhausted fixtures are errors. Matching includes method, URL target/query, meaningful request headers and exact body bytes. Host case and an empty root path are normalized; request header names are normalized and sorted, preserving the order of duplicate names. Default ports are not canonicalized.

Concurrent callers use the order in which their requests reach the client actor. This is an explicit session ordering rule, not a promise that the scheduler reproduces order across separate runs. Serialize distinct calls when their ordering matters, or use separate cassette clients. Batch output order remains input order regardless of admission order. No request-history log grows behind mismatch diagnostics.

## Recording and secrets

Recording performs real live requests. Status, credential-filtered headers, admitted bytes, trailers, failure and local cancellation are written incrementally. Returning early records the observed prefix and terminal outcome without draining the response. Captured chunk boundaries are observations, not a stable wire framing API.

Use `recording.finish_wait(recorded.recording, 5000)` to seal new reservations and await publication. It never drains HTTP: accepted consumers must finish or close their bodies. `WaitTimeout` removes only this wait; finalization continues. One active waiter is allowed; overlapping waits receive `Busy`. `cassette.finish` retains its immediate Busy behavior. Successful or failed finalization is stable while the recording owner lives. Further requests after sealing are refused before submission. Stop `recorded.client` separately; a normal explicit stop still allows finalization of the recorded cancellations.

Capture/persistence failure is separate from the HTTP outcome. A recording budget or write failure does not turn an already received HTTP response into a failed remote operation. Writer acknowledgements apply backpressure to further demand. If persistence stalls until the request deadline, capture fails; already completed HTTP remains available. `recording.abort` abandons capture while keeping live HTTP usable.

Credential headers (`authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`, `x-goog-api-key`) are excluded from stored request/response/trailer metadata and matching. Other headers remain significant. Bodies and URL queries remain exact and **can contain secrets**. Body/query redaction is an optional HTTP Gun feature that is not implemented. It would need an explicit query policy and bounded whole-body transformation or exclusion, with matching rules consistent across recording and playback. Per-chunk string replacement would not safely cover split secrets. Choose whether a session is appropriate to record.

Fixtures use one strict JSON schema with byte lengths, base64 bodies and the format marker `"http_gun": 1`. The package is unreleased; earlier experimental layouts have no migration support. Incompatible data fails explicitly, and no package version bump is needed for pre-release cleanup. Capture has a finite encoded-byte budget and exchange-count limit. Publication uses an atomic hard link for `RefuseExisting` or rename for explicit `ReplaceExisting`, on the destination filesystem. Unfinished recordings never publish a completed fixture. Failed or interrupted sessions can leave private temporary directories beside the destination; they are not replay fixtures. Atomic publication prevents readers from seeing a partly assembled fixture; it does not promise survival after power loss. Durable publication is an optional HTTP Gun feature, requiring file and directory synchronization under a stated operating-system/filesystem contract. It does not require changes to Gun or Cowlib.

## Validation and boundaries

```sh
./dev/env sh dev/gate fast  # format, check, build, tests, FFI warnings, boundaries
./dev/env sh dev/gate full  # also streaming consumers, nghttpd, batch/recording/load checks
sh dev/matrix              # isolated full gates on OTP 29, 28 and 27
sh dev/linux-gate          # optional isolated ARM64 Linux matrix via Docker
```

The toolchain and Hex packages are locked. Public dependency bounds admit stdlib 0.71 and 1.x; the full gate also resolves an independent stdlib 1.0.5 consumer and runs the fast suite on that version. Unpublished Sinal uses one canonical local source; independent gates materialize its verified snapshot in temporary workspaces. See the [source arrangement](docs/OBSERVATIONS.md#one-sinal-source). Cassette IO uses `file_streams` 1.x (from 1.7.0) and `simplifile` 2.x (from 2.7.0), with small bridges only for missing primitives and exception cleanup. See the [filesystem decision](docs/FILESYSTEM.md). Gates use loopback H1/TLS/H2 servers and temporary fixtures, with no provider credentials or public application endpoints. Initial toolchain/package installation may require network access. CI runs the full gate for each selected runtime. The pinned nghttpd1.70.0 server supplies independent TLS/H2 interoperability; controlled servers supply synchronized faults.

See the [current API/adoption follow-up](docs/ADOPTION_IMPROVEMENTS.md), [validation evidence](docs/VALIDATION.md), [guarantees and optional features](BOUNDS.md), [the architecture sketch](docs/DESIGN.md), [progressive wave history](docs/implementation/gleam-first/wave-tracker.md) and [provenance](docs/PROVENANCE.md).

The requested [Dream comparison](docs/DREAM_COMPARISON.md) pins its `codex/http-client-combined` revision and records native-suite results, public contract checks and repeated H1 workloads. Reproduce separately with `./dev/env python3 dev/comparison/run.py all --output build/comparison-recheck`. It is not a production dependency or part of the normal gate. The original 1,000-caller slowdown led to a [Gleam pool correction](docs/BURST_FIX.md): the repeated burst median fell from 705.99 to 45.33 ms with four connections. The report preserves the original results, final measurements, differing connection policies and one failed Dream rerun.

The [adoption follow-up](docs/ADOPTION_VALIDATION.md) records the public batch fix, reference-derived lifecycle tests, independent nghttpd checks, sustained load and [isolated streaming LLM consumer](examples/llm/README.md). That archived example proves text-stream composition and cancellation. LLM Wire’s session runtime has since migrated at `1c0ad614`; use the separate [current downstream gate](docs/DOWNSTREAM.md) to validate the actual selected checkout.

Streamed uploads, redirect policy, decompression, proxies/mTLS, cookies/cache adapters and optional generic SSE remain follow-on scope. Protocol upgrades/tunnels are not a body-stream API. Provider reducers, tool calls, schemas, token usage and agent continuation belong above this library. Gun/Cowlib remain unmodified and own HTTP parsing, HPACK and protocol state; OTP owns TLS. HTTP Gun owns correct use of their supported APIs, admission, cleanup and truthful error reporting. Inherited allocation behavior and the HTTP/2 draining race do not establish dependency defects or justify a hardening project. Optional body/query redaction and durable publication belong to this client.
