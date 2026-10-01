# Adoption validation follow-up

Destination-policy update (2026-10-01): the full HTTP Gun gate passes120 tests and all consumers on Darwin ARM64/OTP29,28,27. The migrated LLM Wire source still compiles, but its local live tests must explicitly permit loopback under the new default. Unmodified:175 passes/48 failures. Isolated test/example setup adaptation:223 passes, public boundary and local H2 through1000 callers. No production LLM Wire or sibling source changed. Warden remains unmigrated; its release/adapter acceptance is separate. See [current validation](VALIDATION.md) and [downstream notes](DOWNSTREAM.md).

Historical adoption: LLM Wire migrated at `1c0ad614149b6ba286a6f778e223bd294f403b30`, with HTTP Gun `ebf2b479761e8c932b0c85a8f83cf8460c014d4f` unchanged. Wave18 reran223 tests, the actual public consumer and six negative compilation controls, live recording/offline playback, and independent verified TLS/H2 at1/10/100/1000 callers on Darwin ARM64/OTP29. These are specific receipts, not universal readiness. See [current downstream validation](DOWNSTREAM.md) and [receipt](evidence/wave18/current-downstream/receipt.json).

The rest of this report preserves waves10–12 and their historical migration status. The archived LLM example still supplies useful text-stream scenarios, but does not prove current downstream compatibility.

All six full local gates pass: OTP 27/28/29 on Darwin ARM64 and Linux ARM64. The client now has real streaming-consumer, independent-server and sustained-load evidence for controlled adoption.

The owner's follow-up authorizes fixes and focused reference validation after the historical [adoption review](ADOPTION_REVIEW.md). This report supersedes that review's implementation status; its original evidence remains intact.

## What changed

Batch workers now capture one request and the operation/destination, instead of the scheduler's pending requests and completed results. Capture acknowledgements and recording writer workers follow the same rule. Final publication receives only its directory, destination, options and count. All changes are in Gleam; Gun/Cowlib and the production FFI remain unchanged.

The public batch regression reproduced the defect before the fix. Three warmed fresh-VM runs with four workers/four H1 connections gave these medians:

| Requests | Before ms | After ms |
| ---: | ---: | ---: |
| 500 | 36.771 | 19.812 |
| 1000 | 116.238 | 36.374 |
| 2000 | 408.884 | 67.674 |
| 5000 | 2377.275 | 166.490 |
| 10000 | not run | 327.580 |

All results had correct bytes. The 5,000-request median improved 14.3×. The retained full-gate regression checks tenfold input growth with a generous noise allowance; it is not an absolute speed promise. [Red/green receipts](evidence/wave10/) preserve exact trials.

## Streaming consumer and reference coverage

The isolated [LLM consumer](../examples/llm/README.md) now uses scoped incremental reads. A real local test first failed with the old buffered implementation, then passed when provider completion could return without HTTP EOF. The example checks progress before EOF, caller stop, partial disconnect evidence, idle expiry, status/Retry-After, compression refusal, finite line/body limits and live recording followed by offline replay through the same function. All1196 split points of three provider text fixtures pass, including UTF-8 and CRLF boundaries.

Only the example retains reviewed LLM Wire framing code and provider fixture strings. Production HTTP Gun remains generic. Exact source hashes and the license are retained. The sibling's session runtime is unchanged.

Reference scenarios added through public HTTP Gun calls:

| Reference | Retained observation |
| --- | --- |
| Gun flow suite | 25 successive H1 responses, each with 25 chunks of 4096 bytes and duplicate trailers, reuse one socket after exhausted credit |
| Finch lifecycle | Normal caller exit closes an unfinished body; batch owner death cancels workers and restores admission |
| Finch/Gun shutdown | An accepted H2 sibling finishes while GOAWAY drains the connection; explicit fresh work succeeds after supported shutdown observation |
| ReqCassette/Mint methods | 65 ordered responses contain all 256 byte values at different chunk boundaries; mismatches preserve each expected exchange |

Existing deadline, caller-death, FIFO/fairness, H2 cancellation/window, writer-backpressure and persistence-failure tests remain. The fast suite now has62 tests. The referenced upstream suites were not executed in this follow-up; scenarios were re-expressed at our public boundary. [Reference revisions/hashes](evidence/adoption-review/reference-sources.json), [consumer source](evidence/wave11/donor-source.json), and [exact checks](evidence/wave11/final.log) establish the scope.

The first new draining test attempted another request before connection-down notification. Gun truthfully returned `ConnectionFailed/MayHaveBeenSent`. The test now synchronizes on the documented observable shutdown; this does not add atomic GOAWAY admission, retry a failed request or claim a dependency defect.

## Independent HTTP/2 server

The full gate now runs released **nghttpd 1.70.0**, pinned through the existing Nix lock. It is dev-only infrastructure. Its independent C HTTP/2 implementation complements the controlled Cowlib test server. The gate covers verified TLS/ALPN, byte-exact binary PUT/downloads, HEAD, 404 response data, trailers, 1/10/100/1000 concurrent callers, a stalled large stream alongside 1000 bounded batch requests, two local cancellations, and a 32 MiB sibling completing after cancellation.

Server logs establish that all HTTP request streams use **one TLS connection**, with **two RST_STREAM frames**. The peer advertises eight concurrent streams; the client config allows 100 and must observe the lower peer limit. Final public counters show zero body handles and zero waiters. Logs are parsed incrementally; only a 256KiB diagnostic prefix is retained, with a hash and total byte count for the complete log. These are client interoperability tests, not protocol certification.

Reproduce: `./dev/env python3 dev/nghttpd.py`. For the separate sustained check: `./dev/env python3 dev/nghttpd.py --soak-seconds 60`.

A 60-second Darwin run completed 317,900 steady requests (81,382,400 response bytes) on one connection with no failures. Sampled whole-VM memory peaked at 64,066,243 bytes, the largest mailbox at 12 messages, and the final body/waiting counters were zero. The load uses batches of 100, eight workers and a 10 ms pause between batches. It is a practical sustained check, not a production latency or leak certification. The first retained run wrote the full verbose log before retaining a bounded prefix; later gate runs stream/count diagnostics directly. [Soak receipt and raw measurements](evidence/wave12/soak/) preserve that distinction.

The recording-pressure check performs 256 binary POST/echo exchanges with 16 workers and four H1 connections: 8 MiB of request plus response bytes, actual incremental writes/final publication, and byte-exact offline replay. The initial Darwin capture/finalize elapsed 228,955 µs with sampled peak VM 60,186,964 bytes and largest mailbox 15. Full runtime receipts also include this workload.

## Readiness and remaining work

The HTTP byte-stream, cancellation and recording capabilities have substantially stronger consumer and independent-server evidence. They are suitable for controlled adoption through public imports. A full LLM Wire runtime cutover remains a separate sibling-package change: preserve tool/continuation/structured-output handling, remaining request budget, owner/deadline policy and complete retry evidence. The text-oriented example does not claim that migration is finished.

Optional features remain optional: streamed uploads, redirect/decompression policy, proxies/mTLS, cookie/cache adapters, generic SSE, body/query redaction and crash-durable fixture publication. No parser hardening or upstream repair was added. The existing post-parse allocation and non-atomic draining boundaries remain accurately documented.

Final runtime outcomes and frozen-input receipts are recorded in [VALIDATION.md](VALIDATION.md). Production handwritten FFI remains **72 lines /3,650 bytes / 12 bindings**: Gun calls/message adaptation, monotonic time, exception-safe scope cleanup, unique temporary paths and empty-directory removal. No Erlang pool, body owner or recording server was added.
