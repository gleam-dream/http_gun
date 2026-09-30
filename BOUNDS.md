# Guarantees, inherited behavior and optional features

HTTP Gun enforces application admission and storage limits. These are not a bound on the Erlang VM, TLS buffers, Gun/Cowlib parsing or all incoming mailbox allocations.

| Limit | Default | Enforcement point |
| --- | ---: | --- |
| Open connections | 16 total, 4/origin | Before Gun open; connecting sockets occupy slots |
| H2 streams/connection | 100 | Before submission, reduced by peer SETTINGS; no H2 streams before initial SETTINGS |
| Active body handles | 128 | Before body-owner creation; finished explicit handles count until closed/dead |
| Waiting requests | 128 | Client admission; connecting reservations have separate connection-bounded slots |
| Request body | 1 MiB | Before admission |
| Header names + values | 16 KiB, 100 pairs | Request validation; response informational/final headers and trailers **after parsing** |
| Admitted data chunk | 64 KiB | After Gun delivers a binary |
| Retained body queue | 128 KiB | Before adding delivered bytes to HTTP Gun's queue |
| Buffered collection | 8 MiB | While collecting the ordinary owned stream |
| Batch | 10,000 inputs, 1–1,024 workers | Before worker creation; results retained until the batch returns |
| Script/cassette values | 16 MiB estimated data | Before starting playback; caller supplies encoded-file read/parse limit |
| Recording | 16 MiB encoded data, 10,000 exchanges | Before queuing each writer fragment; a smaller positive budget is configurable |
| Request deadline | 30 s | From before admission through connection and unfinished response consumption |
| Recording finish waiter | 1 | Extra concurrent waits return Busy; timeout/death removes the waiter without aborting finalization |
| Connection timeout | 5 s | Minimum of configured connection timeout and remaining request budget |

Limits are finite integers; configuration validation rejects invalid capacities before client startup. The caller supplies `next`'s local wait. Per-request monotonic deadlines can shorten the client ceiling. A scoped cancellation token is a Gleam actor; each admitted pending/body owner monitors it, and release removes its monitor. Token termination latches cancellation without retaining completed-request history. Applications bound the number of token scopes they create. Completed HTTP is not retrospectively made unsuccessful because a read happens after its deadline. Capture may separately fail if it cannot finish within that budget.

The configured header count is also passed to Gun’s supported `max_headers` option for H1 and H2. H2 receives one extra allowance for the `:status` pseudo-header; HTTP Gun still checks ordinary headers and trailers against the exact application count. A dependency limit can surface as a transport failure and may close the connection. The byte limit remains an application check after parsing. Other parser settings retain the released defaults: H1 incomplete header/trailer blocks have soft limits of 100,000/10,000 bytes; H2 fragmented header blocks use 32,768 bytes. These count different representations and are not interchangeable with the sum of header-name/value bytes.

Gun flow credit counts **messages, not bytes**. The owner starts with one credit and renews it on demand, accounting for frames already delivered. Supported H2 receive windows are 16,384 bytes per stream and 65,535 per connection at startup. These do not turn the configured chunk limit into a wire allocation limit. A legal peer response that produces an oversized delivered binary can receive typed `LimitExceeded(kind, limit, observed)`; adjust policy for the workload.

No eager body-forwarding process exists. Empty DATA is not retained as an unbounded list of zero-byte chunks. Admitted chunks and pending capture events remain finite; recording has a single writer and acknowledgements gate subsequent demand. Finishing assembles bounded per-exchange files, so finalization can transiently allocate up to a capture budget plus encoding/copy overhead. Disk reads stop after the explicit file limit plus one byte. JSON decoding and byte-count checks occur after that bounded read; they are not parser allocation certification.

External callers can enqueue messages faster than an Erlang actor receives them. Admission limits apply once HTTP Gun processes each call, not before its message exists in the mailbox. Use bounded `batch` or caller concurrency appropriate to the configured client. Sampled mailbox/memory measurements are workload evidence, not a universal guarantee.

Gun 2.6.0 and Cowlib 2.20.0 are unmodified releases. Gun owns framing, compression negotiation mechanics, HTTP/2 state, HPACK and protocol errors; OTP owns TLS and DNS. HTTP Gun never requests response decompression and passes content encoding through. Gun retries are disabled. Supported settings notifications adjust H2 capacity, and connection failures/draining invalidate leases. HTTP/2 allows GOAWAY to race with new streams ([RFC 9113 §6.8](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.8)); Gun exposes no atomic draining/admission transaction. HTTP Gun must stop using known failed/draining capacity, release leases and report racing submissions conservatively, without replay. This is a protocol race to handle, not evidence that Gun needs patching. An unexpected body-owner initialization failure closes its connection because the stream reference may be unavailable; affected siblings receive failures.

Final response headers/statuses and trailers are preserved. Informational responses are checked then discarded; protocol upgrades are refused as request failures. There is no WebSocket, CONNECT tunnel, proxy, streamed upload, cookie, cache, redirect or provider-specific subsystem. This release's documented public API is Erlang-only. Internal-module annotations hide documentation; they are not a security boundary against importing internal functions. Opaque capability constructors are compiler-enforced, and lifecycle/concurrency guarantees are enforced by the owning actors.

## Responsibility and optional client features

| Concern | Classification | HTTP Gun's responsibility |
| --- | --- | --- |
| Allocations inside Gun/Cowlib/OTP | Inherited behavior; no whole-stack memory bound or demonstrated defect | Use supported settings correctly, bound admitted data, report the point of enforcement honestly |
| GOAWAY racing with submission | Protocol/dependency API boundary | Reuse eligible connections, clean up failures and return conservative evidence; no hidden replay |
| Body/query redaction | Optional feature not implemented in HTTP Gun | Define explicit query filtering and bounded whole-body transformation/exclusion, including replay matching, if added |
| Crash-durable fixture publication | Optional feature not implemented in HTTP Gun | Add file and directory synchronization with documented platform semantics if selected; atomic visibility alone is insufficient |

Recording removes a short explicit credential-header list, not all conceivable secrets. Queries, bodies and unlisted custom headers can contain secrets. They remain exact in fixtures today. An interrupted writer may leave temporary data; only a successfully published fixture is replayable. Publication is atomic on the destination filesystem; cross-filesystem publication and survival after power loss are not promised. Neither optional feature requires modifying Gun/Cowlib.

Filesystem operations use released libraries where their semantics fit: bounded raw reads and exclusive writes through file_streams, and permissions/link/rename/file removal through simplifile. The remaining bridges supply unique candidate paths, empty-directory removal and exception cleanup. See [the reviewed guarantees and choices](docs/FILESYSTEM.md).

Typed transport causes report only recognized Gun/OTP reasons; unknown reasons remain UnknownTransport. The safe formatter omits free-form content. The single fixture schema preserves typed diagnostics and requires observed limit sizes; older experimental layouts are rejected. These diagnostics do not strengthen allocation, remote-execution or atomic draining guarantees. Recording wait timeout does not abort capture; an abort cannot undo an already committed atomic publication.
