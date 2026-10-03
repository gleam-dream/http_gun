# Adoption readiness and reference tests — 2026-09-30

Historical review of04ef776 before the authorized fixes. See [the follow-up results](ADOPTION_VALIDATION.md) for current status; the findings below preserve what was observed before implementation.

Reviewed commit **04ef776**, created locally at the owner's request. Its pre-commit gate passed 57 tests, formatting, check/build, FFI warnings and boundaries. The preceding full gates passed on OTP27/28/29. Nothing was pushed or published. This follow-up is a review and reference inventory; it changes no implementation or accepted design.

**Recommendation: use HTTP Gun for a controlled integration, but do not yet treat it as a qualified replacement for LLM Wire's existing transport.** The byte-stream and cancellation primitives are implemented and tested. The LLM integration test is buffered, and this review found another avoidable whole-state capture in batch workers. Address that performance issue and prove the real LLM streaming integration before broad adoption.

## Streaming capabilities

| Required behavior | Current evidence and boundary |
| --- | --- |
| Pull arbitrary response bytes without collecting the whole body | `open` / `body.next`, binary H1/H2 tests, 32 MiB incremental load |
| Scoped early termination | `with_response` closes on normal return or exception; controlled server observes closure |
| Explicit cancellation | `body.close` is idempotent and may be called by another holder; pending reads unblock when the body owner stops |
| Shared cursor and one consumer | Copies share actor state; wrong-owner and conflicting-read tests |
| Read timeout distinct from request deadline | Read timeout preserves the stream; overall expiry terminates unfinished HTTP work |
| Cleanup on caller death or client shutdown | Process monitors, pool release and existing lifecycle tests; local cancellation does not imply remote rollback |
| H2 sibling isolation | Negotiated multiplexing and cancellation/reset tests; queued streams resume on the same connection |
| Backpressure and finite admitted storage | Gun credit plus body chunk/queue limits, without an eager forwarding process; inherited allocations remain outside this guarantee |
| Completion with trailers | `body.End(trailers)` and buffered collection preserve trailers |
| LLM progress, SSE framing, tools and terminal interpretation | Belong above HTTP Gun. The current isolated example does not exercise incremental integration |

The [LLM example](../examples/llm/src/http_gun_llm_consumer.gleam) calls `http_gun.send` at line73, converts the complete body to a string, then splits events. Its `main` uses one scripted OpenAI text response. It proves public provider encoding/reduction composition, not live streaming, early provider completion, tool/structured streaming, cross-provider behavior, or application cancellation through HTTP Gun.

The inspected LLM Wire checkout is clean at `bbde1d927675e3fe55dcbc5f456a9bcb6fe24107`. It still depends directly on Gun and uses its own internal transport. No sibling was modified. Its owner implements idle deadlines, cumulative response-byte limits and semantic progress tracking. These should remain in LLM Wire when integrating HTTP Gun. The adapter must preserve status/Retry-After handling, compressed-stream refusal, remaining overall budget, cancellation and conservative retry evidence. HTTP Gun supplies `NotSubmitted` / `MayHaveBeenSent`; LLM Wire adds observed bytes and semantic progress.

HTTP Gun currently sets the overall budget per client, defaults to 30 seconds and requires a positive finite deadline. It has no independent idle timeout, per-request deadline override or pre-header cancellation handle. A caller can cancel opening/queued work by ending its owning worker; a returned body can be closed directly. These distinctions need an explicit integration mapping, not provider-specific additions to this library. An LLM idle timeout can be enforced above the byte stream with `next` and `close`.

## Review judgments

### 1. Adherence

The reviewed source keeps application orchestration in Gleam and supported transport operations in the narrow FFI, matching DESIGN.md's ownership and delivery contracts. Live, scripts, playback and recording share the same pool/body API. No added protocol implementation or dependency patch was found.

The architecture is coherent, but the completed-wave evidence must not be read as proof of LLM transport migration. DESIGN.md delivery6 requires an isolated LLM example; that exists. A migration-grade streaming example is a further acceptance task. Proposed `(in-place-fix, now)`: add that public consumer and integration evidence before switching LLM Wire's runtime.

Scope: inventory of all 16 production Gleam modules and both Erlang bridges; focused review of public entry points, pool/body/batch/recording state transitions, codecs, persistence, gates and consumers. The design is ordinary Markdown with no formal coverage map or layer-rendering gate. This is a manual readiness review, not a complete machine-checked conformance proof or dependency/parser audit. No open design verification ledger exists.

### 2. Specification

The original required HTTP capabilities have implementations and retained tests; no additional missing byte-stream primitive was established by this review. The owner now asks whether streaming is ready for LLM Wire adoption. That stronger claim remains unproven: the external example buffers before parsing, and the existing LLM runtime is not wired to HTTP Gun.

Proposed `(in-place-fix, now)`: demonstrate incremental progress before HTTP EOF, consumer stop, provider terminal before EOF, split UTF-8/SSE boundaries, status errors, disconnects, owner death, H2 sibling survival and real record/replay through the actual consumer path. Keep provider parsing and retry decisions in the consumer. Do not report this work as already executed.

### 3. Standards

No new violation of AGENTS.md's language/dependency/workspace rules was found in the reviewed scope. The local commit's fast gate passed; previous full runtime receipts remain applicable to unchanged production files. Siblings and oversight were read-only. Raw historical evidence retains original whitespace/ANSI output; source/document whitespace checks pass outside those receipts.

### 4. Craft

**Strong finding — unnecessary state copied into each batch worker.** At [batch.gleam](../src/http_gun/internal/batch.gleam), lines150–157, the spawned closure references `state.subject` and `state.run`. Generated Erlang retains the entire `State`, which includes pending inputs and accumulated results. The same capture pattern remains in recorder job dispatch and body capture acknowledgements; their performance impact was not measured here.

The state/robustness probe used only `http_gun.batch`, four workers, four H1 connections, 3-byte responses, a 60-second request budget and a warmed local server. Three fresh-VM trials completed every result correctly, with unchanged production source:

| Batch size | Median ms | Range ms |
| ---: | ---: | ---: |
| 500 | 35.402 | 34.787–36.802 |
| 1,000 | 119.723 | 114.789–121.915 |
| 2,000 | 416.408 | 415.096–441.880 |
| 5,000 | 2,422.881 | 2,412.306–2,598.869 |

Doubling 1,000 to 2,000 takes about 3.5 times as long. The capture is confirmed structurally; the measurements establish a public batch scaling problem without claiming an exact attribution percentage. The earlier Dream comparison's four-worker case uses a common harness scheduler, not this public batch function, so its 35 ms result does not cover this path. VM reduction counts in this probe grow roughly linearly and alone would miss the elapsed-time growth.

Proposed `(in-place-fix, now)`, strength **strong**: capture only the subject, run function, index and input; add a public batch scaling regression and rerun batch/caller-death gates. Inspect other process-crossing callbacks under the same rule. This is HTTP Gun work, with no Gun/Cowlib/compiler patch. Evidence: [probe source](evidence/adoption-review/batch-probe.gleam.txt), [raw runs](evidence/adoption-review/batch-probe.jsonl), [generated capture](evidence/adoption-review/batch-capture.txt), [receipt](evidence/adoption-review/receipt.json). No durable fix was applied during this review.

Modeling, interface depth and composition remain suitable for a small HTTP library. Additional robustness evidence is worth adding: cancellation versus data/EOF/timeout races, exact-once lease release, changing H2 capacity, shutdown with pending work and sustained recording pressure. These are coverage recommendations, not demonstrated failures. Proposed `(in-place-fix, tracked)`.

## References worth adopting as scenarios

Exact revisions and reviewed file hashes are retained in [reference-sources.json](evidence/adoption-review/reference-sources.json). Downloaded source and license files remain in ignored `build/adoption-references`. No donor source was copied into HTTP Gun and none of these upstream suites was executed during this review.

| Priority / reference | Useful scenarios and use in HTTP Gun |
| --- | --- |
| First: local LLM Wire tests, revision above | `llm_wire_provider_fragmentation_test` checks all byte split points across OpenAI/Anthropic/Google; `llm_wire_owner_test` covers read-timeout races and cleanup; integration tests cover live streams, disconnects, compression refusal and TLS. Re-express transport-level observations through HTTP Gun and run the real LLM consumer above it. Keep reducers/SSE outside HTTP Gun. |
| First: [Finch H2 pool tests](https://github.com/sneako/finch/blob/3387d4be15d2d56ad18e878e62bea0e354385f15/test/finch/http2/pool_test.exs), [H1 pool tests](https://github.com/sneako/finch/blob/3387d4be15d2d56ad18e878e62bea0e354385f15/test/finch/http1/pool_test.exs) | Normal/abnormal caller exit, cancellation after completion, late replies after timeout, initial SETTINGS waiters, pending requests on disconnect, and in-flight responses completing after GOAWAY. Test our observable outcomes rather than copying Finch's pool internals or retry policy. |
| First: [Gun 2.6 flow suite](https://github.com/ninenines/gun/blob/9d40b0ff2de1546e5c613205c4f25aaefffc2569/test/flow_SUITE.erl), [shutdown suite](https://github.com/ninenines/gun/blob/9d40b0ff2de1546e5c613205c4f25aaefffc2569/test/shutdown_SUITE.erl) | Exhausted credit at body end/trailers followed by keepalive reuse; one slow H2 stream beside fast streams; owner loss and GOAWAY with active work. These are direct references for correct supported-API use. |
| Next: [Mint properties](https://github.com/elixir-mint/mint/blob/fb850d3714e4d79b9112d8056fe87cfd96b84f21/test/mint/http1/conn_properties_test.exs), [H2 connection tests](https://github.com/elixir-mint/mint/blob/fb850d3714e4d79b9112d8056fe87cfd96b84f21/test/mint/http2/conn_test.exs) | Random response segmentation should preserve bytes/trailers; cancellation followed by late frames should not disturb siblings. Use the property-testing method at our public boundary, not Mint's parser/HPACK tests or H1 pipelining architecture. |
| Next: [ReqCassette sequential tests](https://github.com/lostbean/req_cassette/blob/cb0251ca394952de46007bb32f5051feb66e896e/test/req_cassette/sequential_matching_test.exs) | Mixed request sequences, repeated identical requests, exhausted sessions and cross-process ordering. Add binary codec roundtrip properties. Preserve HTTP Gun's stricter mismatch-without-consumption and offline-only contract; reject first-match reuse and malformed-fixture fallback. |

## Benchmarks and fault coverage

Keep the existing Dream comparison, but add public `batch` as its own case. Measure repeated H2 workloads against an independent local server such as [nghttpd](https://nghttp2.org/documentation/nghttpd.1.html), with cold connection setup, warmed reuse, many origins, realistic latency and cancellation while siblings run. The current controlled H2 server uses Cowlib; another implementation would strengthen interoperability evidence.

[h2load](https://nghttp2.org/documentation/h2load-howto.html) supplies useful controls for connection count, streams, duration, warmup and receive windows. It exercises the server as a separate HTTP client; it does **not** benchmark HTTP Gun directly. Use it to check that the test server is not the bottleneck, then run the HTTP Gun workload against that server with disclosed comparable limits.

[Toxiproxy](https://github.com/Shopify/toxiproxy) can provide repeatable local latency, bandwidth restrictions, stalls and resets without changing Gun. Prefer the existing synchronized server when it can express a fault more directly. Neither tool has been installed or adopted as a dependency by this review. Ordinary [h2spec](https://github.com/summerwind/h2spec) targets servers and protocol conformance; it is not a direct client-orchestration gate for this package.

Recommended measured workloads: 1/10/100/1,000 callers; batches up to the supported 10,000 inputs; 60-second steady traffic plus a longer soak; large and slow streams; mixed origins; repeated cancellation; recording while requests run. Track first-byte latency, inter-chunk delay, cancellation-to-release time, throughput, p50/p95/p99, sockets and sampled memory/mailboxes. Check resource recovery after load, and timestamp work from intended arrival so client queue delay remains visible. None of those proposed additional measurements is claimed as executed here.

## What remains before broader adoption

1. Correct and regress the batch capture/scaling issue. Audit analogous recording callbacks and measure recording pressure.
2. Build an isolated, real streaming LLM integration with the existing provider/owner contracts. Prove progress before EOF, local cancellation and error/retry evidence. Switching the sibling LLM Wire runtime is separate work; this review kept it read-only.
3. Add the targeted lifecycle/flow scenarios above, independent-server H2 qualification, sustained load and Linux runtime gates. Existing local receipts cover Darwin; configured Linux CI has not yet run.

Optional product features remain separate: streamed uploads; redirect and decompression policies; proxies/mTLS; cookies/cache adapters; generic SSE convenience; body/query redaction; crash-durable fixture publication. Informational response callbacks, upgrades/tunnels and richer DNS/TLS/socket diagnostic detail are also not provided by this small public API. These are not all prerequisites for LLM adoption. Bodies/queries staying exact and lack of power-loss durability are client feature choices, not missing Gun/Cowlib repairs.

Proposed cure pairs: `(in-place-fix, now)` for batch capture and LLM streaming qualification; `(in-place-fix, tracked)` for broader lifecycle/interoperability/load evidence. There is no proposed dependency replacement or protocol-hardening project. The remaining integration decision is how LLM Wire maps its existing owner/deadline/evidence contract onto HTTP Gun's body owner; settle that through a concrete consumer, preserving both packages' responsibilities.
