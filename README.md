# HTTP Gun

An independent HTTP client for Gleam on Erlang/OTP, using released Gun for transport. Public values, pool admission, body ownership, batches, cassette matching and recording coordination are implemented in Gleam.

Requests use `gleam/http/request.Request(BitArray)`. Responses preserve status codes, duplicate headers, arbitrary bytes and trailers. Non-2xx statuses are data. There are no automatic retries, redirects or decompression.

## Ordinary requests

```gleam
import gleam/http/request
import http_gun
import http_gun/config

pub fn main() {
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(req) = request.to("http://localhost:8080/data")
  let result = http_gun.send(client, request.set_body(req, <<>>))
  let _ = http_gun.stop(client)
  result
}
```

`send` returns `Result(Buffered, Failure)`. `Buffered` contains a standard `Response(BitArray)`, separate trailers and the observed `H1`, `H2` or `Offline` protocol. It collects the same stream used by streaming callers, enforcing the configured collection limit and closing on failure.

## Streaming and batches

```gleam
// Returning after one chunk closes locally, even if the callback raises.
let first = http_gun.with_response(client, req, fn(response) {
  body.next(response.body, 1000)
})

// At most ten workers. Results retain the input order, including failures.
let results = http_gun.batch(client, requests, 10)
```

Import `http_gun/body` for `next`, `close`, `collect` and `protocol`. `next` yields `Chunk(BitArray)` or `End(trailers)`. The outer result from `with_response` reports opening failure; the callback keeps its own return type, including its own `Result`.

Advanced callers can use `open` to obtain `Response(Body)` and explicitly `close` its opaque body. The process that opens the response owns consumption. Copies share one cursor. A read while another is pending returns `ReadConflict`; a different consumer otherwise receives `WrongOwner`. Handles do not transfer ownership. Close is idempotent and can be requested by another holder.

A read-wait timeout returns `ReadTimeout` while preserving the stream and outstanding demand. The overall request deadline covers admission, connection setup and consumption; expiry terminates unfinished HTTP work. Completed data remains readable until close or owner death. Early close, scope exit, consumer death and client shutdown release the lease once. Local cancellation says nothing about whether the server continued processing the request.

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

Defaults: H1, verified system TLS trust, 30-second request deadline, five-second connection budget, 16 connections, four per origin, 100 streams per H2 connection, 128 active body handles and 128 waiting requests. Byte defaults and their precise scope are in [BOUNDS.md](BOUNDS.md).

`CustomCa(path)` replaces system trust with a CA file while retaining hostname verification. Each client owns its pool; different trust or transport policies never share connections. `PreferHttp2` negotiates H2 over TLS and otherwise uses H1. `RequireHttp2` requires H2 over TLS; explicit plaintext HTTP uses H2 prior knowledge. Eligible connections are reused before another is opened. Idle sockets yield global slots to other origins. H1 leases are exclusive; H2 leases respect configured and observed peer capacity.

`http_gun.child(settings)` supplies a standard Gleam OTP supervisor child specification. The client process is linked to its starter; `stop` cancels active work and closes connections. A supervisor restart creates a new client capability; old handles remain closed. Gun application startup uses OTP. The library does not stop shared Gun/SSL applications when one client stops.

`Failure(reason, evidence)` distinguishes invalid input, admission, connection, stream, ownership, deadline, limit and fixture failures. `NotSubmitted` describes failures known to precede submission. `MayHaveBeenSent` is conservative, including uncertain client/process races. Neither value establishes remote execution. Status interpretation and retry decisions belong to the caller. `snapshot` returns finite connection/body/waiting counters without request history.

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

Consume or close bodies, then call `cassette.finish(recorded.recording)` and inspect its result. `Busy` refuses unfinished HTTP or writer work. Successful or failed finalization is stable while the recording owner lives. Further requests after finalization are refused before submission. Stop `recorded.client` separately; a normal explicit stop still allows finalization of the recorded cancellations.

Capture/persistence failure is separate from the HTTP outcome. A recording budget or write failure does not turn an already received HTTP response into a failed remote operation. Writer acknowledgements apply backpressure to further demand. If persistence stalls until the request deadline, capture fails; already completed HTTP remains available. `recording.abort` abandons capture while keeping live HTTP usable.

Credential headers (`authorization`, `proxy-authorization`, `cookie`, `set-cookie`, `x-api-key`, `api-key`, `x-goog-api-key`) are excluded from stored request/response/trailer metadata and matching. Other headers remain significant. Bodies and URL queries remain exact and **can contain secrets**. Body/query redaction is an optional HTTP Gun feature that is not implemented. It would need an explicit query policy and bounded whole-body transformation or exclusion, with matching rules consistent across recording and playback. Per-chunk string replacement would not safely cover split secrets. Choose whether a session is appropriate to record.

Fixtures use versioned JSON with byte lengths and base64 bodies. Capture has a finite encoded-byte budget and exchange-count limit. Publication uses an atomic hard link for `RefuseExisting` or rename for explicit `ReplaceExisting`, on the destination filesystem. Unfinished recordings never publish a completed fixture. Failed or interrupted sessions can leave private temporary directories beside the destination; they are not replay fixtures. Atomic publication prevents readers from seeing a partly assembled fixture; it does not promise survival after power loss. Durable publication is an optional HTTP Gun feature, requiring file and directory synchronization under a stated operating-system/filesystem contract. It does not require changes to Gun or Cowlib.

## Validation and boundaries

```sh
./dev/env sh dev/gate fast  # format, check, build, tests, FFI warnings, boundaries
./dev/env sh dev/gate full  # also external consumers, type rejection, load checks
sh dev/matrix              # isolated full gates on OTP 29, 28 and 27
```

The toolchain and Hex packages are locked. Cassette IO uses `file_streams` 1.7.0 and `simplifile` 2.7.0, with small bridges only for missing primitives and exception cleanup. See the [filesystem decision](docs/FILESYSTEM.md). Gates use loopback H1/TLS/H2 servers and temporary fixtures, with no provider credentials or public application endpoints. Initial toolchain/package installation may require network access. CI runs the full gate for each selected runtime.

See [validation evidence](docs/VALIDATION.md), [guarantees and optional features](BOUNDS.md), [the architecture sketch](docs/DESIGN.md), [progressive wave history](docs/implementation/gleam-first/wave-tracker.md) and [provenance](docs/PROVENANCE.md).

The requested [Dream comparison](docs/DREAM_COMPARISON.md) pins its `codex/http-client-combined` revision and records native-suite results, public contract checks and repeated H1 workloads. Reproduce separately with `./dev/env python3 dev/comparison/run.py all --output build/comparison-recheck`. It is not a production dependency or part of the normal gate. The original 1,000-caller slowdown led to a [Gleam pool correction](docs/BURST_FIX.md): the repeated burst median fell from 705.99 to 45.33 ms with four connections. The report preserves the original results, final measurements, differing connection policies and one failed Dream rerun.

Streamed uploads, redirect policy, decompression, proxies/mTLS, cookies/cache adapters and optional generic SSE remain follow-on scope. Protocol upgrades/tunnels are not a body-stream API. Provider reducers, tool calls, schemas, token usage and agent continuation belong above this library. Gun/Cowlib remain unmodified and own HTTP parsing, HPACK and protocol state; OTP owns TLS. HTTP Gun owns correct use of their supported APIs, admission, cleanup and truthful error reporting. Inherited allocation behavior and the HTTP/2 draining race do not establish dependency defects or justify a hardening project. Optional body/query redaction and durable publication belong to this client.
