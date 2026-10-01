# Application-owned streaming jobs

Run `./dev/env sh dev/async-consumer` from HTTP Gun's root. The full gate runs it too. It builds a separate package with public imports, runs a two-job offline demo, then eleven synchronized loopback test groups. No sibling checkout or provider endpoint is required.

[feed_job.gleam](src/http_gun_async/feed_job.gleam) is application recipe code, not an exported HTTP Gun task API. [workflow.gleam](src/http_gun_async/workflow.gleam) contains REST, byte-counting download and grouped-request examples. [The executable tests](test/http_gun_async_test.gleam) show the complete wiring, including live, script, actual recording and strict disk playback. Their local servers/certificates are copied from the package's test infrastructure at build time.

The application starts one shared supervised client:

```gleam
let ready = process.new_subject()
let assert Ok(supervisor) = feed_job.supervise(config.default(), ready)
let assert Ok(client) = process.receive(ready, 1000)
```

`http_gun.child` is a normal OTP child specification. `supervision.map_data` hands each new capability to the application. A service must consume these notifications and replace its current capability after restart; retaining an old one does not reconnect it. The example's test performs one controlled restart. A production service should keep a single current capability in its own state, bound pending jobs and handle repeated restart notifications according to its supervision policy.

For each feed/download, the application starts a worker and later awaits or cancels it:

```gleam
let assert Ok(budget) = deadline.after(5000)
let assert Ok(job) = feed_job.start(client, req, budget, fn(bytes) {
  // Process this bounded chunk here; Continue requests the next chunk.
  // Return Stop for an intentional prefix, or Error(Nil) for a sink failure.
  Ok(feed_job.Continue)
})
let result = feed_job.await(job, 1000)
```

The same worker opens and reads the HTTP body. Its cancellation scope spans admission, connection, response headers and all reads. The controlling process receives the token before opening begins, so cancellation is available even while headers are withheld. Completing one operation leaves the shared client running. The demo admits exactly two jobs; applications must impose their own finite job count, not spawn a worker for every unbounded input.

The sink runs synchronously before the next `body.next`. There is no forwarding loop or body-data mailbox. HTTP Gun keeps one outstanding flow credit and its configured finite chunk/queue limits; credit is a message count, not a byte allocation bound inside Gun/Cowlib. The sink must bound the state it retains. Framing, semantic progress and idle policy belong there. The recipe retries only local `ReadTimeout` waits; it never resubmits an HTTP request. HTTP EOF may already be observed while application processing is still running, so an HTTP deadline cannot interrupt arbitrary sink code.

`feed_job.cancel` is idempotent local cancellation. It does not prove remote receipt or rollback. `await` timing out preserves the operation. Only the creating application process consumes the single completion result; copying a Job does not create another result stream or transfer its lifetime. After consuming the result, discard the Job. The recipe is deliberately not a repeatable future abstraction.

Scope exit closes on success, callback error and exception. Early Stop records/returns only the observed prefix, without draining to EOF. A monitor-only guardian kills the worker when its creating application process dies, including normal exit. Worker death releases its HTTP ownership; the shared client remains usable. `shutdown(job, grace_ms)` cancels, waits a finite grace, then kills only that application's blocked worker and waits up to another1000ms. It is a worker-death bound, not a pool/remote barrier; cleanup proceeds asynchronously. A sink exception is reported as WorkerStopped rather than trying to serialize an arbitrary exception.

HTTP Body copies share one cursor. The opener owns reads. An overlapping pending read returns ReadConflict; another process otherwise receives WrongOwner. Another holder may close idempotently. The executable test demonstrates these advanced cases directly through public Body calls; ordinary feed users receive no Body handle.

The tests cancel during admission, a withheld TLS handshake, response headers and body reads; verify caller/worker death, exceptional and early exit, bounded shutdown of a blocked sink, shared-client shutdown and supervision restart; and cancel one verified H2 stream while an unfinished sibling completes on the same connection. They also check a finite client ceiling versus a longer supplied deadline, expiry while queued with NotSubmitted, non-consuming cassette mismatch, no offline sockets, real prefix capture and capture failure separate from successful HTTP.

The small policy decisions here—two job slots in the demo, one completion recipient, startup wait1000ms, local read waits100ms, Nil sink errors and kill-after-grace—are visible application choices. Change them for your service. They are not additional HTTP Gun promises or a reason to introduce another library orchestration server.

The gate also injects an OTP InitTimeout result at the token-startup boundary in its disposable HTTP Gun copy, then runs a separate process with one scheduler. It verifies the exact mapped Failure, skips the callback and repeats64 failed job starts without leaving unconsumable completion messages. No production test switch is added. The feed worker intentionally retains `with_token` here to distinguish startup from callback completion on its two message channels; the download and grouped REST workflows use `try_with_token` directly.
