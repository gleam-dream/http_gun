# Guarantees, inherited behavior and optional features

HTTP Gun enforces application admission and storage limits. These are not a bound on the Erlang VM, TLS buffers, Gun/Cowlib parsing or all incoming mailbox allocations.

| Limit | Default | Enforcement point |
| --- | ---: | --- |
| Open connections | 16 total, 4/origin | Before resolution/Gun open; resolving and connecting reservations occupy slots |
| H2 streams/connection | 100 | Before submission, reduced by peer SETTINGS; no H2 streams before initial SETTINGS |
| Open body handles | 128 | Before body-owner creation; finished explicit handles count until closed/dead; an H1 readiness job reserves an open slot until admission/refusal |
| Queued requests | 128 | Client admission; connecting reservations have separate connection-bounded slots |
| Request body | 1 MiB | Before admission |
| Header names + values | 16 KiB, 100 pairs | Request validation; response informational/final headers and trailers **after parsing** |
| Buffered response bytes | 128 KiB | Before adding delivered bytes to HTTP Gun's queue; one chunk must fit |
| Collected response body | 8 MiB | While `send` or `batch` collects; the failure carries the status |
| Batch | 10,000 inputs, 1–1,024 workers, 64 MiB retained | Workers before creation; each collected chunk is charged to one shared counter, and positions not yet sent fail once it is exceeded |
| Script/cassette values | 16 MiB estimated data | Before starting playback; caller supplies encoded-file read/parse limit |
| Recording | 16 MiB encoded data, 10,000 exchanges | Before queuing each writer fragment; bodies held for body redaction count too |
| Connect, including DNS and TLS | 5 s | One timer per new connection from resolution start; Gun's own connect and handshake timeouts get the remainder |
| Pool wait | 5 s | From admission until a connection or stream is leased, including an H1 readiness check; a request that opens a connection may wait for the connect timeout instead |
| Request | 30 s | From before admission through DNS, connection, sending and consumption; a view replaces it, shorter or longer; `Infinity` lifts it |
| Idle read | 30 s | While the opener waits for the head or a reader waits with nothing buffered; reset by every delivered event; also the socket `send_timeout` |
| Idle pooled connection | 60 s | A ready connection carrying no request is closed |
| Shutdown drain | 5 s | `stop` waits for open bodies, then cancels them |
| Recording staging directory | 1 per recording | Removed on publication, abort, any capture or finish failure, owner death and recorder crash; left behind only if the VM is killed mid-recording or a writer is stuck in a blocking file operation |
| Recording finish waiter | 1 | Extra concurrent waits return Busy; timeout/death removes the waiter without aborting finalization |

Limits are finite integers; configuration validation rejects invalid capacities before client startup. `body.next` waits for data; the request and idle timeouts bound it. `body.next_within` adds a local wait that returns `None` and keeps the stream. A cancellation token is one plain process that each admitted pending/body owner monitors, and release removes its monitor; cancelling kills it, which latches cancellation without retaining completed-request history. Applications bound the number of token scopes they create. Completed HTTP is not retrospectively made unsuccessful because a read happens after its deadline. Capture may separately fail if it cannot finish within that budget.

The configured header count is also passed to Gun’s supported `max_headers` option for H1 and H2. H2 receives one extra allowance for the `:status` pseudo-header; HTTP Gun still checks ordinary headers and trailers against the exact application count. A dependency limit can surface as a transport failure and may close the connection. The byte limit remains an application check after parsing. Other parser settings retain the released defaults: H1 incomplete header/trailer blocks have soft limits of 100,000/10,000 bytes; H2 fragmented header blocks use 32,768 bytes. These count different representations and are not interchangeable with the sum of header-name/value bytes.

Gun flow credit counts **messages, not bytes**. The owner starts with one credit and renews it on demand, accounting for frames already delivered. Supported H2 receive windows are 16,384 bytes per stream and 65,535 per connection at startup. These do not turn the buffered-bytes limit into a wire allocation limit. A legal peer response that produces an oversized delivered binary can receive typed `LimitExceeded(kind, limit, observed)`; adjust policy for the workload.

No eager body-forwarding process exists. Empty DATA is not retained as an unbounded list of zero-byte chunks. Admitted chunks and pending capture events remain finite; recording has a single writer and acknowledgements gate subsequent demand. Finishing assembles bounded per-exchange files, so finalization can transiently allocate up to a capture budget plus encoding/copy overhead. Disk reads stop after the explicit file limit plus one byte. JSON decoding and byte-count checks occur after that bounded read; they are not parser allocation certification.

External callers can enqueue messages faster than an Erlang actor receives them. Admission limits apply once HTTP Gun processes each call, not before its message exists in the mailbox. Use bounded `batch` or caller concurrency appropriate to the configured client. Sampled mailbox/memory measurements are workload evidence, not a universal guarantee.

Lifecycle observations go through `sinal.emit`. Without an application route, handlers run synchronously in the pool and body processes; route `["http_gun"]` to a forwarder to bound them by its capacity instead. `config.with_observations` uses a forwarder directly. HTTP Gun retains no history and emits no body chunks. Overflow/unavailable forwarders drop events without changing HTTP results; shutdown does not drain telemetry.

Gun 2.6.x and Cowlib 2.20.x are unmodified releases; [GUN_AUDIT.md](docs/GUN_AUDIT.md) lists the terms HTTP Gun relies on. Gun owns framing, compression negotiation mechanics, HTTP/2 state, HPACK and protocol errors; OTP owns TLS and DNS. HTTP Gun never requests response decompression and passes content encoding through. Gun retries are disabled. Supported settings notifications adjust H2 capacity, and connection failures/draining invalidate leases. HTTP/2 allows GOAWAY to race with new streams ([RFC 9113 §6.8](https://www.rfc-editor.org/rfc/rfc9113.html#section-6.8)); Gun exposes no atomic draining/admission transaction. HTTP Gun must stop using known failed/draining capacity, release leases and report racing submissions conservatively, without replay. This is a protocol race to handle, not evidence that Gun needs patching. An unexpected body-owner initialization failure closes its connection because the stream reference may be unavailable; affected siblings receive failures.

Final response headers/statuses and trailers are preserved. Informational responses are checked then discarded; protocol upgrades are refused as request failures. There is no WebSocket, CONNECT tunnel, proxy, streamed upload, cookie, cache, redirect or provider-specific subsystem. This release's documented public API is Erlang-only. Internal-module annotations hide documentation; they are not a security boundary against importing internal functions. Opaque capability constructors are compiler-enforced, and lifecycle/concurrency guarantees are enforced by the owning actors.

## Responsibility and optional client features

| Concern | Classification | HTTP Gun's responsibility |
| --- | --- | --- |
| Allocations inside Gun/Cowlib/OTP | Inherited behavior; no whole-stack memory bound or demonstrated defect | Use supported settings correctly, bound admitted data, report the point of enforcement honestly |
| GOAWAY racing with submission | Protocol/dependency API boundary | Reuse eligible connections, clean up failures and return conservative evidence; no hidden replay |
| Header, query and body redaction | Implemented (`config.with_redaction`) | Credential headers by default; configured headers, named query parameters and a whole-body function, applied identically to recording and playback matching |
| Crash-durable fixture publication | Optional feature not implemented in HTTP Gun | Add file and directory synchronization with documented platform semantics if selected; atomic visibility alone is insufficient |

Recording removes the configured redaction: the credential-header list by default, plus any headers, named query parameters and body function the application adds. It is not a general secret detector: unlisted headers, query parameters and unredacted bodies remain exact in fixtures. An interrupted writer may leave temporary data; only a successfully published fixture is replayable. Publication is atomic on the destination filesystem; cross-filesystem publication and survival after power loss are not promised. Neither optional feature requires modifying Gun/Cowlib.

Filesystem operations use released libraries where their semantics fit: bounded raw reads and exclusive writes through file_streams, and permissions/link/rename/file removal through simplifile. The remaining bridges supply unique candidate paths, empty-directory removal and exception cleanup. See [the reviewed guarantees and choices](docs/history/FILESYSTEM.md).

Typed transport causes report only recognized Gun/OTP reasons; unknown reasons remain UnknownTransport. The safe formatter omits free-form content. The single fixture schema preserves typed diagnostics and requires observed limit sizes; older experimental layouts are rejected. These diagnostics do not strengthen allocation, remote-execution or atomic draining guarantees. Recording wait timeout does not abort capture; an abort cannot undo an already committed atomic publication.

## Destination policy

Policy is fixed at client startup. Default public-only admission rejects all
loopback/private/reserved addresses; explicit loopback/private permissions do
not admit reserved space. Classification covers RFC1918, RFC6598 and IPv6 ULA;
unspecified/link-local/multicast/broadcast, documentation and benchmark ranges,
192.0.0/24, 192.88.99/24, 6to4, Teredo, ORCHID, 100::/64 and 3fff::/20 are reserved.
Metadata addresses 100.100.100.200 and fd00:ec2::254 are reserved even under private-network
permission. IPv4-mapped and 64:ff9b::/96 inherit the embedded IPv4 class. Invalid
components fail closed. Outside these exceptions only 2000::/3 IPv6 global
unicast is public; other special IPv6 space is conservatively reserved.

The case-insensitive `only_hosts` list is an additional restriction on the
original host and, for `host:port` entries, its port; not its resolved IP or
URL path. It does not impose HTTPS,
certificate revocation checking or application authorization. Applications may
restrict schemes/ports separately. An empty allowlist refuses all live origins.

A hostname resolution obtains both families exactly once for each new
connection, then validates the entire answer before opening Gun on the selected
IP tuple. A family with no records contributes an empty list; a failed lookup
fails closed even if the other family succeeded. There is no alternate-address
retry or fallback to Gun DNS. TLS uses the original hostname and HTTPS matching;
IP literals omit the SNI option entirely, never `disable`, so OTP verifies the
connected IP SAN. A caller-supplied Host header does not change DNS/TLS policy.

**Pool rule:** only a checked connection can enter this client's pool. The pool
is isolated by immutable client configuration and canonical origin (lowercase
host, scheme and port). It reuses eligible connections without re-resolving;
DNS answers are trusted for the duration of one connection only. Every new or
replacement connection calls the configured resolver again and checks its
complete answer. OTP may use its normal resolver cache; HTTP Gun adds no
cross-connection DNS cache. Policy changes require a new
client, or a narrower per-call view (`http_gun.with_destination`): a view's
request must pass every policy, including the full resolved answer of a pooled
connection it would reuse, so a view never widens the client's policy. DNS changes do not rewrite
or retroactively revoke an already checked connection.

Each resolving connection reservation has one Gleam worker and one short-lived
Gleam guardian, so their count is bounded by connection capacity. They receive
no HTTP body or pool history. The guardian can kill a blocked resolver on its
request deadline or pool death; queued cancellation/owner death releases its
unused reservation. Other eligible origins can progress while resolution is
blocked. Custom resolvers are trusted code and own resources they spawn.
No universal bound is claimed for OTP resolver allocations or user callbacks.

The request budget covers DNS, connection/TLS and HTTP consumption; the
connect timeout separately bounds DNS, TCP and TLS of each new connection.
Both TCP and TLS sockets have `send_timeout` and `send_timeout_close`, set from
the idle timeout (no bound when it is `Infinity`). A native write
timeout can fail earlier than the overall request ceiling. Reuse does not
reset these socket settings: each request's independent body-owner timer still
enforces its earlier deadline, cancels the stream and releases its lease. H1
failure closes its exclusive connection; H2 cancellation preserves healthy
siblings. Buffered uploads are additionally capped before admission. Tests use
16 MiB uploads to fresh/reused non-reading local TCP/TLS peers and verify prompt
HTTP completion and cleanup under a 300 ms request budget. Timing bounds allow
scheduler tolerance; this is not a real-time scheduling guarantee or proof that
the remote application stopped processing.

Gun connection notifications go to the pool; response messages go to the body
owner. Neither uses the HTTP caller as Gun's owner/reply target. Public calls
consume their typed result and flush their own monitor on completion. Local
cancellation/deadline tests check that caller mailboxes gain no response data or
monitor messages, including after connection/client cleanup.

## Delivered headers and wire parsing

HTTP Gun checks the complete delivered header list, including the final header,
against its name/value byte and pair limits. Informational heads, final heads
and trailers are each checked. This is not a raw status-line/whitespace/delimiter
byte bound and cannot prevent prior Gun/Cowlib allocations. Delivered header
names must be tokens; values reject control bytes except HTAB. This admission
check is shared by live and simulated response processing.

The released Gun/Cowlib parser rejects the tested bare-LF head, signed
content-length and signed/non-hex chunk sizes. It accepts controls in header
values; HTTP Gun now rejects those delivered values. It also accepts controls
in status **reason phrases**, which Gun discards before sending its public
response event. HTTP Gun therefore cannot reject them without changing or
replacing the dependency parser. The owner explicitly accepted documenting this
exception on 2026-10-01. The retained test records this behavior; it does not
claim fully strict status-line parsing.

A close-delimited TLS response has no independent length to prove completeness.
When a peer closes without `close_notify`, a body accepted as EOF can be
indistinguishable from truncation. Consumers needing completeness should use
HTTP framing with a declared length/chunk terminator and validate their payload.
No extra draining, parser or TLS implementation is added here.


## H1 readiness and error precision

Before reusing an H1 connection, a bounded Gleam preparation job calls the
supported `gun:info/1` API and accepts only its connected HTTP state. This keeps
Gun's TLS-alert wait (currently up to200ms before `gun_down`) off the pool actor
and prevents submission to connections already observed closing or dead. At
most one check exists per H1 connection; it also reserves active capacity,
preserving admission order when capacity is one. The request's original
absolute budget and cancellation/owner lifetime govern the job. Readiness is
valid only for the immediate admission pass, never a cached liveness promise.
DNS and readiness jobs share only a small Gleam worker-lifetime function.

An unused failed connection can be discarded and replaced before `gun:request`.
This is preparation of the original queued request, not replay. The peer can
still close after inspection; such a submitted request keeps conservative
`MaybeSent` evidence and never retries. H2 continues to use supported
capacity/down events, with the existing non-atomic draining boundary.
Case-insensitive comma-separated `Connection: close` tokens in an H1 request
or response prevent reuse after HTTP completion. Early cancellation still
closes H1 and preserves healthy H2 siblings.

Gun's structured `{connection_error, limit_reached, _}` response-header/trailer
rejection becomes `HeaderLimitReached`. It does not expose the measured size
or distinguish count from block bytes; `LimitExceeded` remains reserved for
values HTTP Gun actually measured. Raw explanations never enter public errors.
Invalid status and signed content lengths can surface only as dependency
process crashes; truncated fixed-length bodies and invalid chunk sizes can
both surface as `PeerClosed`. These remain failures without invented precision.
No stack-trace matching, custom wire parser or dependency patch is used.

The accepted reason-phrase limitation also covers a mixed-terminator response
such as `HTTP/1.1 200 OK\nContent-Length: 2\r\n\r\nok`: Gun can interpret
the LF-containing text as the reason phrase, discard it and deliver a
close-delimited response. Therefore the client does not claim universal
bare-LF/status-line rejection. Warden's unchanged strict framing table still
fails this row; accepting the limitation does not make that test pass.
