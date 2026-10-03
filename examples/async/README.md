# Application-owned streaming jobs

Run `./dev/env sh dev/async-consumer` from HTTP Gun's root. The full gate runs it too. It builds a separate package with public imports, runs a two-job offline demo, then eleven synchronized loopback test groups. No sibling checkout or provider endpoint is required.

[feed_job.gleam](src/http_gun_async/feed_job.gleam) is application recipe code, not an exported HTTP Gun task API. [workflow.gleam](src/http_gun_async/workflow.gleam) contains REST with a bounded retry, byte-counting download and shared-budget grouped-request examples, and maps each failure's `error.kind` to an application decision. [The executable tests](test/http_gun_async_test.gleam) show the complete wiring, including live, script, actual recording and strict disk playback. Their local servers/certificates are copied from the package's test infrastructure at build time.

The application starts one shared supervised client and keeps one handle to it:

```gleam
let name = process.new_name("http_client")
let assert Ok(_supervisor) = feed_job.supervise(config.default(), name)
let client = http_gun.named(name)
```

`http_gun.supervised(config, name)` is a normal OTP child specification; the client registers under `name`. `http_gun.named(name)` returns a handle that keeps working across restarts, so jobs and services never replace a capability. While the client is restarting, calls fail with `ClientClosed` and `NotSent`, which `error.is_retryable` reports as safe to retry. The example's test kills the client once and sends through the same handle after the restart.

Per-call settings are client views. Each `http_gun.with_*` returns a new handle over the same pool: `with_deadline` gives a request the remaining part of a shared budget, `with_timeout` replaces the client's request timeout for one kind of call, longer or shorter, and `with_cancellation` attaches a token.

For each feed/download, the application starts a worker and later awaits or cancels it:

```gleam
let budget = deadline.after(5000)
let assert Ok(job) = feed_job.start(client, req, budget, fn(bytes) {
  // Process this bounded chunk here; Continue requests the next chunk.
  // Return Stop for an intentional prefix, or Error(Nil) for a sink failure.
  Ok(feed_job.Continue)
})
let result = feed_job.await(job, 1000)
```

The same worker opens and reads the HTTP body through `http_gun.with_response`, whose error mapper turns an opening failure into the job's own `Problem`. Its cancellation scope spans admission, connection, response headers and all reads. The controlling process receives the token before opening begins, so cancellation is available even while headers are withheld. Completing one operation leaves the shared client running. The demo admits exactly two jobs; applications must impose their own finite job count, not spawn a worker for every unbounded input.

The sink runs synchronously before the next `body.next`. There is no forwarding loop or body-data mailbox. HTTP Gun keeps one outstanding flow credit and its configured finite buffered-bytes limit; credit is a message count, not a byte allocation bound inside Gun/Cowlib. The sink must bound the state it retains. Framing and semantic progress belong there. `body.next` waits until bytes arrive; the job's deadline, the client's idle timeout and the token bound that wait, so the recipe has no local read loop. `body.next_within` is the call for a local wait that returns `None` and leaves the stream intact. The recipe never resubmits an HTTP request. HTTP EOF may already be observed while application processing is still running, so an HTTP deadline cannot interrupt arbitrary sink code.

`feed_job.cancel` is idempotent local cancellation. It does not prove remote receipt or rollback. `await` timing out preserves the operation. Only the creating application process consumes the single completion result; copying a Job does not create another result stream or transfer its lifetime. After consuming the result, discard the Job. The recipe is deliberately not a repeatable future abstraction.

Scope exit closes on success, callback error and exception. Early Stop records/returns only the observed prefix, without draining to EOF. A monitor-only guardian kills the worker when its creating application process dies, including normal exit. Worker death releases its HTTP ownership; the shared client remains usable. `shutdown(job, grace_ms)` cancels, waits a finite grace, then kills only that application's blocked worker and waits up to another 1000 ms. It is a worker-death bound, not a pool/remote barrier; cleanup proceeds asynchronously. A sink exception is reported as WorkerStopped rather than trying to serialize an arbitrary exception.

HTTP Body copies share one cursor. The opener owns reads. An overlapping pending read returns ReadConflict; another process otherwise receives WrongOwner. Another holder may close idempotently. The executable test demonstrates these advanced cases directly through public Body calls; ordinary feed users receive no Body handle.

The tests cancel during admission, a withheld TLS handshake, response headers and body reads; verify caller/worker death, exceptional and early exit, bounded shutdown of a blocked sink, shared-client shutdown within its shutdown timeout and supervised restart behind one named handle; and cancel one verified H2 stream while an unfinished sibling completes on the same connection. They also check that a view's deadline replaces a shorter client request timeout, that a local read wait leaves the stream intact, expiry while queued with NotSent, non-consuming cassette mismatch, no offline sockets, real prefix capture and capture failure separate from successful HTTP.

The small policy decisions here—two job slots in the demo, one completion recipient, startup wait 1000 ms, two REST retries, Nil sink errors and kill-after-grace—are visible application choices. Change them for your service. They are not additional HTTP Gun promises or a reason to introduce another library orchestration server.

The gate also injects an OTP InitTimeout result at the client's process start in its disposable HTTP Gun copy, then runs a separate process with one scheduler. It verifies that `http_gun.start`, `testing.playback` and `cassette.record` report `StartFailed`, that the application's supervised client fails its supervisor's start, that a named handle with no running client fails with `ClientClosed` and `NotSent`, and that 64 failed starts leave no messages in the caller's mailbox. No production test switch is added.
