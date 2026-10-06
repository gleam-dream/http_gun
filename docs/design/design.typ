#import ".render/designlib.typ": *

#let title = [HTTP Gun]
#let accent = "teal"

#let facts(headers, rows) = md-table(headers.len(), headers + rows.flatten())

#let body = [
  #section(title: "Foundation", lead: "Generic HTTP exchanges with explicit ownership.", body: [
    #goal(title: "One client serves ordinary and composed HTTP calls")[
      HTTP Gun supplies Erlang/OTP applications with binary HTTP requests, process-owned response streams, finite collection, connection reuse, deterministic offline playback and explicit live recording. Ordinary applications and provider clients use the same public interface.
    ]
    #goal(title: "Failure preserves decisions the caller must make")[
      Request failures retain typed causes, conservative submission evidence and available response facts. The caller decides status semantics, application retry, framing and external effect reconciliation.
    ]
    #no-goal(title: "Application effects remain outside HTTP ownership")[
      HTTP Gun owns no provider outcome, workflow continuation, agent checkpoint, transfer recovery, business idempotency, automatic request retry or ambient cookie/cache policy.
    ]
    #no-goal(title: "Gun and Cowlib own wire parsing")[
      The package supplies no custom HTTP/TLS parser, dependency patch, WebSocket API, HTTP/3 API or server framework. It claims no bound on total VM memory or allocations that precede its admission checks.
    ]
    #invariant(title: "An admitted invocation performs one attempt", enforcement: "mechanism")[
      HTTP Gun never resubmits after invoking Gun's request API. Gun reconnection retry is disabled. Preparing a replacement unused connection before submission preserves the original attempt.
    ]
    #invariant(title: "One process owns each body cursor", enforcement: "mechanism")[
      A body actor serializes every read, deadline and close over one cursor. Only the process that opened the response may read it. Every copied body capability targets that actor.
    ]
    #invariant(title: "Every live connection has an admitted address set", enforcement: "mechanism")[
      Every new live connection uses a checked IP tuple and original TLS identity. Client and view policies intersect. No replacement connection bypasses address admission or silently falls back to Gun DNS.
    ]
    #invariant(title: "Fixtures never trigger a live fallback", enforcement: "mechanism")[
      Script and cassette playback are offline. Missing, corrupt, incompatible, mismatched and exhausted inputs remain explicit failures.
    ]
    #principle(title: "Keep state and policy in Gleam")[
      Gleam owns configuration, admission, pool state, body state, batch scheduling, matching, codecs, recorder coordination and filesystem policy. Foreign code binds Gun events and genuinely missing runtime/filesystem primitives. #adr(1)
    ]
    #principle(title: "State limits at the boundary that enforces them")[
      Message credit, post-parse header checks, retained-body limits and encoded fixture budgets describe different resources. A limit on admitted values must not be presented as a parser or whole-stack allocation guarantee.
    ]
    #principle(title: "Expose independent completion authorities")[
      HTTP completion, application consumption, local cancellation, observer delivery and recording publication remain separate facts. A failure in one does not invent success or failure in another.
    ]
  ])

  #pagebreak(weak: true)
  #pending-ledger(
      pending-entry(title: "Streamed upload producer contract", kind: "build", adr: 9)[
        Retain bounded producer demand, finish/abort, early response, producer failure and request replayability. Buffered uploads are the current path. An arbitrary enumerable is insufficient evidence of backpressure.
      ],
      pending-entry(title: "Explicit redirect and decompression policies", kind: "build", adr: 9)[
        Redirects require hop/deadline bounds, method/body transitions, origin/downgrade policy and credential stripping. Decompression requires encoded and decoded limits, incremental expansion bounds and truthful response headers.
      ],
      pending-entry(title: "Proxy and client certificate pool identity", kind: "build", adr: 9)[
        Retain explicit proxy routing, tunnel/proxy credentials and mTLS identity in connection keys. Every supported path requires independent policy, TLS and lifecycle tests.
      ],
      pending-entry(title: "Optional cookie cache and SSE helpers", kind: "build", adr: 9)[
        Cookie/cache adapters have caller-owned policy, storage, capacity and lifetime. A generic SSE helper is pure framing over HTTP bytes. Provider framing remains in its provider package until this helper exists.
      ],
      pending-entry(title: "Choose crash-durable fixture publication", kind: "ruling", adr: 5)[
        Atomic visibility is implemented. A power-loss durability promise would require file and directory synchronization with explicit supported-platform semantics. It has no accepted implementation contract.
      ],
      pending-entry(title: "Resolve recording cleanup promise strength", kind: "ruling", adr: 10)[
        Public prose promises removed staging data on abort and failure. The implementation ignores removal failures and can return while a blocked writer's cleaner waits. Decide whether best-effort cleanup is the public contract or whether typed cleanup completion is required.
      ],
  )

  #pagebreak(weak: true)
  #section(title: "System at a glance", lead: "One HTTP exchange context with separate invariant owners.", body: [
    #points(
      [The context contains client lifecycle, admission and destination checking, pool leasing, body ownership, collection and batching, playback and recording, observations and foreign boundaries. Their shared exchange vocabulary earns one context.],
      [The pool owns capacity and scheduling. A body actor owns response progress. A recorder owns capture ordering and publication. Those owners exchange typed messages without sharing mutable state.],
    )
    #diagram(altitude: "L3", viewpoint: "runtime", title: "Runtime ownership and calls", caption: [Request data flows to its body owner; response messages never use the HTTP caller as Gun's reply target.], nodes: (
      (id: "app", label: "Application", kind: "actor", external: true),
      (id: "pool", label: "Client pool", kind: "aggregate", tint: "teal"),
      (id: "prep", label: "Preparation jobs", kind: "component", tint: "teal"),
      (id: "body", label: "Body owner", kind: "aggregate", tint: "teal"),
      (id: "gun", label: "Gun connection", kind: "external-system"),
      (id: "rec", label: "Recorder", kind: "aggregate", tint: "teal"),
      (id: "obs", label: "Sinal / application handlers", kind: "external-system"),
    ), edges: (
      (from: "app", to: "pool", relation: "call", label: "open / send / batch"),
      (from: "pool", to: "prep", relation: "call", label: "DNS / H1 readiness"),
      (from: "pool", to: "body", relation: "call", label: "lease + start"),
      (from: "body", to: "gun", relation: "call", label: "submit / credit / cancel"),
      (from: "app", to: "body", relation: "call", label: "read / close"),
      (from: "body", to: "rec", relation: "dataflow", label: "acknowledged observations"),
      (from: "pool", to: "obs", relation: "pubsub", label: "admission milestones"),
      (from: "body", to: "obs", relation: "pubsub", label: "HTTP milestones"),
    ))
    #facts(([Unit], [Authority and public boundary], [Children]), (
      ([Client], [`config`, `start`, `supervised`, `named`, views, `stop`], [Configuration; view composition; client lifecycle]),
      ([Admission and pool], [Request validity, destination decisions and lease membership], [Origin queue; resolution; H1 readiness; H2 capacity; release]),
      ([Body], [`open`, `with_response`, `body.next`, `next_within`, `close`], [Head admission; demand; byte retention; terminal delivery; cleanup]),
      ([Collection], [`send`, `body.collect`, `batch`], [Per-response overflow; shared batch budget; bounded workers]),
      ([Fixtures], [`testing`, `cassette`, `redaction`], [Match keys; schema; capture reservations; writer; finalization; publication]),
      ([Observation], [`telemetry`, client labels and correlation], [Milestones; delivery mode; application forwarders]),
      ([Foreign boundary], [Gun/OTP and filesystem operations], [Event decoding; typed causes; atomics; time; scope cleanup; upgrade audit]),
    ))
    #points(
      [Deployment is one Erlang/OTP application with client-local actors and native Gun connections. There is no service endpoint, external database or deployment topology to configure. A cassette is an optional filesystem artifact rather than shared runtime storage.],
      [Applications translate HTTP results into LLM, MCP, OIDC or business vocabularies. HTTP Gun imports none of those packages. Sinal supplies correlation and observation delivery; file_streams and simplifile supply filesystem mechanisms.],
    )
  ])

  #section(title: "Local model", lead: "Values, authorities and state links within the HTTP exchange context.", body: [
    #subsection(title: "Values and refinements", [
      #facts(([Value], [Meaning and refinement], [Ownership]), (
        ([Request], [`Request(BitArray)` preserves method, scheme, host, port, target, ordered headers and whole body bytes. Construction is pure.], [Caller authors; admission validates]),
        ([Response], [Final status and ordered duplicate headers plus a body capability or collected bytes. Trailers remain separate. Non-success statuses remain data.], [Body owner observes]),
        ([Origin], [Lowercase unbracketed host, effective 80/443 or explicit port, TLS choice. Port is 1–65535.], [Pool derives at validation]),
        ([Config and view], [Opaque immutable configuration and per-handle overrides. A view contains optional timeout, deadline, idle bound, cancellation, body limit, policies and correlation.], [Caller authors; client startup validates config]),
        ([Address], [IPv4/IPv6 integer components. Invalid components classify Reserved. Policy uses Public, Loopback, Private or Reserved.], [Resolver observes; destination policy decides]),
        ([Failure], [Opaque reason, submission evidence, optional final status and retained response headers. Kind is closed; detailed reason/cause unions may grow.], [Boundary that detects failure]),
        ([Deadline and token], [Opaque VM-local monotonic instant; shared latched cancellation capability. Neither is durable or part of cassette matching.], [Caller owns scope]),
        ([Script and cassette], [Ordered request/reply values with bytes, heads, trailers or typed terminal failure. A script's finite estimated data budget differs from file bytes.], [Caller or file decoder supplies]),
        ([Request id and correlation], [Fresh VM-local invocation identity and independently supplied caller correlation. Neither grants retry permission.], [HTTP Gun derives id; caller supplies correlation]),
      ))
      #points(
        [Authority is held by process destinations and opaque capabilities. Names identify a supervised client's current incarnation. They are not credentials or durable exchange identifiers.],
        [Commands include startup, open, read, close, stop, reserve capture, write observation, finish and abort. HTTP heads/bytes/trailers, connection capacity/down signals and local timers are observed events. Observation milestones are best-effort notifications rather than an event-sourced history.],
        [The model census covers four stateful authorities and nine value families. There is no application business entity or remote execution ledger. Local request references index pending work and do not survive restart.],
      )
    ])

    #subsection(title: "Client and connection authorities", [
      #state-type(id: "client-phase", title: "Client phase", variants: ("running", "draining", "closed"))
      #entity(id: "client", title: "Client pool", description: [The aggregate owning one client's capacity, admission and lifetime.], kind: "aggregate", owner: "HTTP exchange", lifecycle: "stateful", domain: "HTTP exchange", tint: "teal")[
        #attribute(id: "phase", name: "Phase", type: "Client phase", provenance: "derived", state-type: "client-phase", state-machine: "client-lifetime")[Established by startup and stop transitions; derived at mutation.]
        #attribute(name: "Configuration", type: "Validated client policy", provenance: "authored")[Immutable startup limits, trust, protocol, destination, redaction and observation choices.]
        #attribute(name: "Capacity membership", type: "Connections, owners and origin queue", provenance: "derived")[Current owned resources and pending work; updated together at admission and release.]
        #relates(cardinality: "1 : 0..n")[owns connection reservations]
        #relates(cardinality: "1 : 0..n")[tracks body owners until close or process death]
      ]
      #state-machine(id: "client-lifetime", subject: "client", state-field: "phase", state-type: "client-phase", title: "Client draining", caption: [Closed includes an absent process. A named handle reaches a replacement pool without reviving old exchanges.], states: ("running", "draining", "closed"), initial: "running", accepting: ("closed",), transitions: (("running", "draining", "stop"), ("draining", "closed", "active leases settle or grace expires"), ("running", "closed", "process loss")))
      #state-type(id: "connection-phase", title: "Connection phase", variants: ("resolving", "connecting", "ready", "checking", "checked", "removed"))
      #entity(id: "connection", title: "Connection reservation", description: [A pool-owned identity for preparation and a native connection's capacity.], kind: "entity", owner: "HTTP exchange", lifecycle: "stateful", domain: "HTTP exchange", tint: "teal")[
        #attribute(id: "phase", name: "Phase", type: "Connection phase", provenance: "derived", state-type: "connection-phase", state-machine: "connection-lifetime")[A transition-derived scheduling state; removed means absent from the pool.]
        #attribute(name: "Origin", type: "Canonical origin", provenance: "derived")[Derived from the first request without changing original HTTP authority.]
        #attribute(name: "Checked answer", type: "Complete admitted address set", provenance: "observed")[The resolver's answer checked before opening; retained for every reuse-policy intersection.]
        #attribute(name: "Used capacity", type: "Active leases", provenance: "derived")[One for H1; concurrent stream count bounded by local and peer capacity for H2.]
        #relates(cardinality: "n : 1")[belongs to one client pool]
        #relates(cardinality: "1 : 0..n")[carries stream leases]
      ]
      #state-machine(id: "connection-lifetime", subject: "connection", state-field: "phase", state-type: "connection-phase", title: "Connection preparation and reuse", caption: [Checking and Checked apply to H1. A checked observation is consumed by one admission pass.], states: ("resolving", "connecting", "ready", "checking", "checked", "removed"), initial: "resolving", accepting: ("removed",), flow: "top-to-bottom", transitions: (("resolving", "connecting", "whole answer admitted"), ("resolving", "removed", "refusal / expiry / no waiter"), ("connecting", "ready", "H2 up"), ("connecting", "checked", "H1 up"), ("ready", "checking", "H1 reuse candidate"), ("checking", "checked", "connected H1 observed"), ("checking", "removed", "unusable / job loss"), ("checked", "ready", "launch or admission pass ends"), ("connecting", "removed", "connect failure"), ("ready", "removed", "down / idle / dirty H1 release"), ("checked", "removed", "shutdown / loss")))
      #points(
        [A vacant client/connection is represented by process absence or removed membership. Restart creates new authority. Checked readiness can be revoked by job failure or discarded at the end of an admission pass.],
        [H2 Ready includes protocol and capacity. Initial capacity is zero until peer SETTINGS. Existing used streams may exceed a newly reduced peer limit; the pool admits no additional stream until usage falls below it.],
      )
    ])

    #subsection(title: "Body and capture authorities", [
      #state-type(id: "body-phase", title: "Body phase", variants: ("opening", "reading", "finished", "rejected", "closed"))
      #entity(id: "body", title: "Body owner", description: [The aggregate serializing one request attempt and response cursor.], kind: "aggregate", owner: "HTTP exchange", lifecycle: "stateful", domain: "HTTP exchange", tint: "teal")[
        #attribute(id: "phase", name: "Phase", type: "Body phase", provenance: "derived", state-type: "body-phase", state-machine: "body-lifetime")[Finished retains success or failure; Rejected retains an opening failure. Closed means actor absence.]
        #attribute(name: "Opening process", type: "Read authority", provenance: "observed")[The caller identity fixed at admission; monitored for its complete lifetime.]
        #attribute(name: "Head and terminal outcome", type: "Observed HTTP facts", provenance: "observed")[Admitted final status and head plus eventual trailers or typed failure.]
        #attribute(name: "Demand and retained bytes", type: "One read wait and bounded byte queue", provenance: "derived")[Current cursor, queue bytes and flow credit; updated by reads and delivered events.]
        #relates(cardinality: "n : 1")[is tracked by one client pool]
        #relates(cardinality: "1 : 0..1")[holds one stream lease]
        #relates(cardinality: "1 : 0..1")[feeds one capture reservation]
      ]
      #state-machine(id: "body-lifetime", subject: "body", state-field: "phase", state-type: "body-phase", title: "Body lifetime and terminal retention", caption: [Reading failures settle in Finished with an error. Closing settles unfinished HTTP and stops the actor; copying a capability never transfers ownership.], states: ("opening", "reading", "finished", "rejected", "closed"), initial: "opening", accepting: ("closed",), transitions: (("opening", "reading", "final head admitted"), ("opening", "rejected", "opening failure"), ("reading", "finished", "EOF / failure / expiry"), ("opening", "closed", "close / owner loss"), ("reading", "closed", "close / owner loss"), ("finished", "closed", "close / owner loss / client loss"), ("rejected", "closed", "opener completes cleanup")))
      #state-type(id: "recording-phase", title: "Recording phase", variants: ("active", "closing", "sealing", "sealed", "broken"))
      #entity(id: "recording", title: "Recording session", description: [The aggregate owning exchange order, writer acknowledgment and publication.], kind: "aggregate", owner: "HTTP exchange", lifecycle: "stateful", domain: "HTTP exchange", tint: "teal")[
        #attribute(id: "phase", name: "Phase", type: "Recording phase", provenance: "derived", state-type: "recording-phase", state-machine: "recording-lifetime")[Finalization transitions derive from reservations, jobs and publication acknowledgment.]
        #attribute(name: "Exchange positions", type: "Ordered capture reservations", provenance: "derived")[Monotonic zero-based positions assigned at reservation, not at HTTP completion.]
        #attribute(name: "Storage budget", type: "Encoded bytes plus held bodies", provenance: "derived")[Conservatively charged before enqueueing fragments or retaining whole-body redaction input.]
        #attribute(name: "Publication choice", type: "Destination and replacement policy", provenance: "authored")[Explicitly chosen at record startup; destination is not part of safe error detail.]
        #relates(cardinality: "1 : 0..n")[owns capture reservations]
        #relates(cardinality: "1 : 0..1")[owns a current writer and a finish waiter]
      ]
      #state-machine(id: "recording-lifetime", subject: "recording", state-field: "phase", state-type: "recording-phase", title: "Recording finalization", caption: [A waiting caller may leave Closing or Sealing without aborting capture. Atomic publication remains the irreversible commit point.], states: ("active", "closing", "sealing", "sealed", "broken"), initial: "active", accepting: ("sealed", "broken"), transitions: (("active", "closing", "finish accepts one waiter"), ("closing", "sealing", "all reservations and writes terminal"), ("sealing", "sealed", "publication job acknowledged"), ("active", "broken", "capture failure / abort"), ("closing", "broken", "failure / abort / owner loss"), ("sealing", "broken", "publication failure / abort race")))
      #points(
        [Capture stream state is AwaitHead, Receiving, Buffering or Ended. Receiving retains chunk framing; Buffering retains the whole body for redaction. Head starts Receiving or Buffering; bytes advance that state; completion/failure ends it. Invalid observation order breaks the recording.],
        [Read wait presence, capture acknowledgment presence and HTTP phase are independent state axes. At most one read wait and one outstanding capture acknowledgment exist per body. A terminal HTTP result cannot become unsuccessful solely because its consumption occurs after the deadline.],
      )
    ])
  ])

  #section(title: "Client configuration and lifecycle", lead: "Pure setup, shared views and explicit resource lifetime.", body: [
    #contract(name: "Client configuration boundary", mission: [Validate complete settings before resources start.], answers: answers-data(
      responsibility: [Own defaults, pure setters and startup validation.],
      interface: [`config.default`, `with_*`, `validate`; `start` or `supervised(config, name)`.],
      interactions: [The validated settings feed pool, body owners, destination preparation and recorder startup.],
      invariants: [A setter starts no process. Invalid settings cannot produce a live pool.],
      failure: [InvalidConfig retains ConfigError; startup failure is StartFailed.],
    ))
    #subsection(title: "Configuration validation and mode choice", [
      #points(
        [`Config`, `Policy`, `Redaction` and `RecordOptions` are opaque caller-built values. Value-first setters permit extension without forcing callers to construct all fields. Returned Buffered and Stats records are read by label; consumers leave room for added fields. #adr(2)],
        [Positive capacities are required for connections, per-origin connections, H2 streams, open bodies, header bytes/count, buffered bytes and batch bytes. Queue, request-body and response-body limits may be zero. Connect, pool and pooled-idle timeouts are positive; shutdown may be zero. Request/idle timeout may be explicit Infinity.],
        [In-memory trust anchors must be nonempty whole-byte values and their list must be nonempty. Invalid host-list entries fail configuration validation. Actual certificate or CA-file validity is established by OTP when connecting, rather than by pure settings construction.],
        [Live startup, offline startup and recording startup return the same Client type. Recording also returns a Recording capability. Application startup chooses a mode explicitly; requests read no environment variables and contain no automatic mode fallback.],
      )
      #behavior(title: "Invalid startup has no usable client", level: "boundary", area: "Client configuration")[
        #given[the complete client settings are invalid]
        #when[the caller starts that client]
        #then[startup returns the typed configuration failure]
        #then[no usable client capability is returned]
      ]
    ])
    #subsection(title: "View composition and time authority", [
      #points(
        [A #term("term-client-view") copies only a handle and its view values. Scalar setters replace their prior value. Destination setters append policies whose intersection applies at every operation. Later correlation replaces earlier correlation.],
        [`cancellation.with_token` creates one token process for its lexical scope. Cancellation kills the token process, which makes every copy remain cancelled. Current pending and body owners receive their monitors' death signal; a later attempt sees the dead token before submission. Completion removes monitors. Callback return, exception or creator death ends the token. Applications bound the number and lifetime of token scopes.],
        [A view's relative request timeout or absolute deadline replaces the startup request timeout, whether shorter or longer. With both supplied, the earlier applies. With neither, the startup timeout starts from the invocation's monotonic entry instant before admission.],
        [The absolute Deadline is VM-local and cannot be serialized as durable policy. Reading remaining duration never renews it. Every public duration is converted to whole milliseconds with sub-millisecond remainders rounded away from zero. Nonpositive Deadline creation is immediately expired.],
        [Views do not change immutable connection trust, protocol, resolver or startup socket timeout options. Idle read can be replaced per view; pooled socket send settings continue to use startup idle timeout. The body owner's independent overall timer still cancels an earlier request budget.],
        [`with_body_limit` replaces collection policy only. Negative view collection limits fail before submission. A zero limit permits an empty body; Truncate can return an empty prefix on overflow.],
      )
    ])
    #subsection(title: "Supervision shutdown and mailbox lifetime", [
      #points(
        [`start` links the pool to its caller. `supervised(config, name)` supplies a child specification; `named(name)` is pure and targets the current registered process. During restart absence, operations return ClientClosed with NotSent. An old body is never revived by pool restart.],
        [`stop` refuses new admission, fails queued work with ClientClosed/NotSent and waits for active leases within shutdown grace. Grace expiry locally closes unfinished bodies and native connections. Completed retained body actors lose the client authority when the pool exits. Repeated stop is harmless.],
        [Shutdown grace bounds the planned drain. Serial body close calls, actor scheduling and synchronous observation handlers are additional work; this is not a hard real-time stop bound.],
        [Pool notifications go to the pool actor. Gun replies go directly to the body owner. Public calls monitor only their own target, consume the typed result and flush that monitor on completion. Response data and stale monitor notifications are not forwarded to the HTTP caller.],
      )
      #behavior(title: "Stop ends admission before draining", level: "boundary", area: "Client lifecycle")[
        #given[the client has pending and active work]
        #when[the caller stops it]
        #then[new and waiting attempts fail before submission]
        #then[active exchanges may finish within the drain period]
        #then[remaining exchanges are locally closed when draining ends]
      ]
    ])
  ])

  #section(title: "Admission and destination policy", lead: "Refuse invalid or unauthorized attempts before submission.", body: [
    #subsection(title: "Request admission order", [
      #points(
        [The invocation entry instant is captured before caller-side validation. Already cancelled tokens, expired absolute deadlines and negative body limits fail early. Body bit size must be divisible by eight. The method and lowercase header names must be tokens. Origin/port and target reject invalid forms.],
        [Paths start with a slash. Host, path and query reject whitespace/control forms checked by admission. Header values reject CR/LF/NUL and delivered request headers also pass the shared token/control/size check. Limits count name plus value bytes rather than wire delimiters.],
        [The pool checks required view destination and request body/header limits, then reserves capture when appropriate. Deadline, monitors and timers belong to the pending entry before leasing. A new request never overtakes an existing request in its origin lane.],
        [The #term("term-origin") is cached after validation. Pending entries, owner indexes, cancellation indexes, FIFO links and waiting count mutate together. Removing expired/dead work unlinks it immediately, including work behind a blocked origin head.],
        [Connecting reservations are distinct from waiting queue entries. A request starting a connection may wait for its connect timer beyond ordinary checkout expiry, while its overall deadline still caps the attempt. Resolving and connecting reservations consume connection capacity.],
      )
      #behavior(title: "A full queue refuses before submission", level: "boundary", area: "Request admission")[
        #given[no eligible lease is available and waiting admission is full]
        #when[another request seeks admission]
        #then[the request fails with capacity refusal and NotSent]
        #then[existing waiting requests preserve admission order]
      ]
    ])
    #subsection(title: "Address classes and policy intersection", [
      #points(
        [Public-only is the default. Loopback and private networks require explicit opt-in. Reserved addresses remain refused under every option. Host lists restrict the original case-insensitive host and optional port; they do not authorize TLS downgrade, DNS aliases, paths or application access.],
      )
      #facts(([Class], [Address classification], [Admission]), (
        ([Loopback], [127/8 and IPv6 loopback], [Explicit client/view permission]),
        ([Private], [RFC1918, carrier-grade 100.64/10 and IPv6 ULA], [Explicit private permission]),
        ([Reserved], [Invalid components; unspecified, link-local, multicast/broadcast; documentation/benchmark ranges; 192.0.0/24; 192.88.99/24; 6to4, Teredo, ORCHID, 100::/64, 3fff::/20; remaining special IPv6 outside public global unicast], [Always refused]),
        ([Metadata exceptions], [100.100.100.200 and fd00:ec2::254], [Reserved even with private permission]),
        ([Embedded IPv4], [IPv4-mapped IPv6 and 64:ff9b::/96], [Inherit embedded IPv4 class]),
        ([Public], [Other admitted IPv4 and remaining 2000::/3 IPv6 global unicast], [Default permitted]),
      ))
      #points(
        [A host list entry is host, host:port, bracketed IPv6 or bracketed IPv6:port. An empty list admits no host. Whitespace, URI delimiters, empty names and invalid ports fail validation. `destination.check` checks literal addresses and the host list without resolving hostname answers.],
        [Plaintext is AllowPlaintext, PlaintextToLoopbackOnly or RequireTls. A loopback-only plaintext choice checks every address in the complete answer, including reuse. HTTPS remains subject to address policy and verified TLS.],
        [Every startup policy and appended view policy must admit the original host/port and every resolved address. No view can widen the client. For `require_view_destination`, one policy must have a host list or refuse an address class admitted by the client. A scheme-only restriction never satisfies it. The required-view check also runs offline. #adr(4)],
      )
      #behavior(title: "A view must select its own destination", level: "boundary", area: "Destination policy")[
        #given[the client requires a view destination]
        #given[the view only tightens the plaintext rule]
        #when[the caller opens a request through that view]
        #then[the request is refused with ViewDestinationRequired and NotSent]
        #then[no address resolution or request submission begins]
      ]
    ])
    #subsection(title: "Resolution TLS and worker ownership", [
      #points(
        [Each new hostname connection obtains A and AAAA answers once, sequentially within one connect budget. A family with no records contributes an empty list. A lookup failure fails closed even when the other family succeeded. A fully empty answer fails.],
        [The #term("term-checked-answer") includes every returned address. The first admitted address is the selected IP tuple. There is no alternate-address retry, Gun DNS fallback or HTTP Gun cross-connection DNS cache. OTP may apply its own resolver cache.],
        [Original host authority and TLS server identity remain distinct from the selected IP tuple. TLS uses peer verification and HTTPS hostname matching. IP literals omit the SNI option entirely; they never use SNI disable. System trust, PEM CA file and DER anchor list replace one another. A caller Host header changes no resolution/TLS authorization.],
        [Each resolving reservation has one Gleam guardian and one linked worker bounded by connection capacity. Pool death or job deadline kills the worker. Request cancellation/owner death removes unused reservations; late answers cannot reopen removed membership. Other origin lanes can progress while a callback blocks.],
        [Custom resolvers are trusted callbacks supplied complete host/budget input. They own resources they spawn and their memory allocations. Killing the worker does not claim cleanup of independently spawned callback resources.],
      )
      #behavior(title: "Mixed address answers fail closed", level: "boundary", area: "Address admission")[
        #given[one resolved address violates an applicable destination policy]
        #when[the complete answer is considered for a new connection]
        #then[the entire attempt is refused before submission]
        #then[an allowed address in that answer is not used as a fallback]
      ]
    ])
  ])

  #section(title: "Connection pool and leases", lead: "Reuse eligible capacity with explicit preparation and release.", body: [
    #contract(name: "Pool lease boundary", mission: [Own finite transport and retained-body admission.], answers: answers-data(
      responsibility: [Serialize queue membership, preparation reservations, connection usage and owner membership.],
      interface: [A validated invocation receives one body owner or a NotSent refusal. Stats expose connections, open bodies and queued requests.],
      interactions: [DNS/H1 jobs report to this incarnation; body owners release leases and report closure separately.],
      invariants: [One H1 lease per connection; H2 usage respects observed and local capacity; retained handles consume finite admission.],
      failure: [Connection loss removes membership; admitted bodies receive their own conservative failure.],
    ))
    #subsection(title: "FIFO lanes and bounded preparation", [
      #points(
        [Live/recording scheduling uses one FIFO lane per canonical origin. An admission pass stops at a blocked lane head and considers other lanes. Lanes that make progress rotate their position. Playback uses one global session lane to preserve matching order.],
        [Reuse comes before opening another connection. If global capacity is full, an unused ready connection for another origin may be evicted when that origin has no waiter. Idle sockets are a cache rather than a permanent capacity claim. #adr(3)],
        [Resolving/connecting/checking slots are finite. Only one new preparation exists per origin while that origin already prepares a connection. At most one H1 readiness job exists per connection. A readiness job also reserves an open body slot to preserve admission order at capacity one.],
        [Work crossing process boundaries captures only required values. A batch worker captures one input and its operation. Release/capture callbacks capture message destinations. They do not capture pool pending queues or completed batch results.],
      )
    ])
    #subsection(title: "H1 readiness and H2 capacity", [
      #points(
        [An H1 lease is exclusive; the package does not pipeline independent requests. Before idle reuse, a bounded Gleam job calls supported `gun:info` and accepts connected HTTP state. Checking never blocks the pool. Checked is valid for one immediate admission pass and is reset if a body cannot launch.],
        [An unusable idle H1 connection is discarded before Gun request invocation. The original request retains position, deadline and cancellation while replacement preparation proceeds. A peer may still close after inspection; that submitted failure remains MaybeSent without retry.],
        [Http1 selects H1. PreferHttp2 negotiates H2 over TLS with H1 fallback; plaintext uses H1. RequireHttp2 refuses H1 negotiation and supports plaintext H2 prior knowledge. HTTP/2 receives no application stream before initial peer SETTINGS. Capacity is the lower of peer and configured stream limits.],
        [Gun owns H2 flow control, framing, GOAWAY and stream state. The pool uses supported up/settings/down events. Eligibility inspection is not atomic with GOAWAY or request submission. A race returns conservative failure and performs no hidden replay. #adr(8)],
        [An unexpected body-owner initialization failure may lack a stream reference; the pool closes that connection and affected siblings can fail. Healthy H2 sibling preservation applies to ordinary stream cancellation, not to lost connection ownership.],
      )
    ])
    #subsection(title: "Lease release and retained handles", [
      #points(
        [#term("term-http-termination") releases the #term("term-stream-lease") exactly once. The #term("term-open-body-slot") remains occupied for a finished explicit handle until close or process death. Stats therefore distinguish finished handles from used transport streams.],
        [Clean H1 completion allows reuse unless request or response contains a case-insensitive comma-separated Connection close token. Early H1 cancel/failure retires the exclusive connection. H2 cancellation cancels that stream and preserves healthy siblings.],
        [Retained bytes/trailers and terminal failure are readable after HTTP completion, even if the deadline subsequently passes. Closing clears cursor authority and is idempotent. Owner death and client loss converge on the same local cleanup.],
        [A ready unused connection gets one generation-marked idle timer. Reuse invalidates its old idle reference. Stale timers cannot close an in-use connection.],
      )
      #behavior(title: "Closing one H2 body preserves siblings", level: "boundary", area: "Connection leases")[
        #given[healthy independent exchanges share an H2 connection]
        #when[one owner closes its unfinished body]
        #then[that exchange settles as local cancellation]
        #then[healthy sibling exchanges remain usable]
      ]
    ])
  ])

  #section(title: "Body demand and response fidelity", lead: "One cursor consumes generic bytes without a forwarding reader.", body: [
    #subsection(title: "Head admission and wire boundaries", [
      #points(
        [`open` returns only after final response headers pass admission. Informational heads are checked then discarded. Final status, duplicate ordered headers, bytes and trailers are preserved. Gun applies HTTP empty-body/framing rules. Protocol upgrades fail as unsupported request outcomes.],
        [The shared delivered-header check counts every pair and every name/value byte, including the final pair. Names are tokens; values reject controls except HTAB. Informational, final and trailer lists each pass it independently. There is no cumulative informational-response count limit beyond the request/idle budgets.],
        [Gun receives the configured ordinary-header count for H1 and one extra H2 allowance for the status pseudo-header. HeaderLimitReached represents a dependency rejection without a measured value. LimitExceeded is reserved for measurements HTTP Gun actually made.],
        [Admission occurs after Gun/Cowlib parsing. It does not bound raw status lines, whitespace/delimiters, TLS buffers, HPACK expansion or parser allocations. Gun discards reason phrases, including experimentally accepted control/mixed-terminator forms. HTTP Gun cannot reject discarded data through this event API. #adr(8)],
        [Invalid status/framing can surface as dependency crash or PeerClosed without precise raw-wire diagnosis. Close-delimited TLS EOF without close_notify can be indistinguishable from truncation. Consumers needing proof of completeness require declared HTTP framing and payload validation.],
      )
    ])
    #subsection(title: "Demand reads and terminal arbitration", [
      #points(
        [The opener is the sole read owner. If a #term("term-read-wait") already exists, another read returns ReadConflict before owner validation. Otherwise another process returns WrongOwner. Another capability holder may close the shared body.],
        [`next` waits for Chunk, End(trailers) or Failure. `next_within` adds a local wait; expiry returns None and removes only that read wait. Already admitted bytes and outstanding credit remain. A polling read still grants demand before local expiry is honored.],
        [The owner maintains one outstanding #term("term-flow-credit"). A reader drains admitted queued bytes before requesting more data. There is no actor that eagerly reads and forwards chunks into another unbounded mailbox.],
        [Every delivered data event decrements credit and undergoes buffered-byte admission before retention. A single chunk must fit. Message credit and supported H2 receive windows do not establish a byte-allocation bound inside Gun/Cowlib/OTP.],
        [Overall expiry, idle expiry, cancellation, close, owner/client death and native failure settle through the owner. Queued accepted bytes can be delivered before the terminal failure; a failed stream does not fabricate successful trailers. HTTP completion cancels its deadline timer unless capture is still pending.],
        [`with_response(client, req, on_failure, run)` maps opening failure to the caller's error type. Its callback returns Result and scope cleanup closes on success, failure or exception. Callback code owns read/application failure mapping; arbitrary callback computation is not interrupted by the HTTP timer after EOF.],
      )
      #behavior(title: "A local read wait preserves the stream", level: "boundary", area: "Response demand")[
        #given[an unfinished response has no available bytes]
        #when[the local read wait expires]
        #then[that read returns no event]
        #then[later reads continue on the same cursor]
      ]
      #behavior(title: "Completed HTTP survives later deadline passage", level: "boundary", area: "Response terminal state")[
        #given[a response has already completed with retained bytes and trailers]
        #when[the owner reads after its request deadline]
        #then[the completed response remains readable]
        #then[deadline passage does not replace completion with failure]
      ]
    ])
    #subsection(title: "Asynchronous application composition", [
      #points(
        [The async recipe uses a shared supervised client and an application-bounded job count. Each job's worker opens and reads its own body inside one cancellation scope. A monitor-only guardian kills the worker when its application owner dies. The recipe adds no library body server or task runtime.],
        [The sink runs synchronously before the next demand. It owns retained state, framing and semantic progress. EOF can precede sink completion; an HTTP deadline cannot interrupt arbitrary sink work. Application shutdown cancels then kills its own worker after finite grace if necessary.],
        [Job await timeout preserves the job. One creating process consumes one completion result. Job copies are not repeatable futures or ownership transfers. One job finishing never stops the shared HTTP client. The preserved executable recipe is `examples/async`.],
      )
    ])
  ])

  #section(title: "Budgets and effect timing", lead: "Independent capacities and clocks apply at named points.", body: [
    #facts(([Resource], [Default], [Admission or timing point]), (
      ([Connections], [16 total; 4 per origin], [Before resolution/Gun open; preparing reservations count]),
      ([H2 streams], [100 per connection], [Before submission; reduced by peer SETTINGS]),
      ([Open bodies / queued requests], [128 / 128], [Before owner creation / pending queue insertion; finished handles and H1 checking slots count]),
      ([Request body], [1 MiB], [Before admission; caller has already allocated bytes]),
      ([Headers], [16 KiB; 100 pairs], [Request validation; informational/final/trailer admission after parsing]),
      ([Buffered response], [128 KiB], [Before appending each delivered chunk]),
      ([Collected response], [8 MiB], [While send/body.collect/batch consume]),
      ([Batch], [10,000 inputs; 1–1,024 workers; 64 MiB], [Before worker creation / shared charging before retaining collected chunks]),
      ([Script data], [16 MiB estimated], [Before playback actor startup; not measured VM memory]),
      ([Cassette read], [Caller max_bytes], [Read at most max_bytes + 1 raw bytes; parse checks encoded string length]),
      ([Recording], [16 MiB encoded; 10,000 exchanges], [Before reservation/fragment enqueue; held redaction bodies charged]),
      ([Connect], [5 seconds], [One absolute budget from DNS start through TCP/TLS]),
      ([Pool wait], [5 seconds], [Admission to lease; new connection starter can use connect wait]),
      ([Request], [30 seconds or view replacement], [Invocation entry through response consumption; Infinity explicit]),
      ([Idle read], [30 seconds or view replacement], [While opener waits for head or reader waits on empty queue; events reset activity]),
      ([Pooled idle / shutdown drain], [60 seconds / 5 seconds], [Ready unused connection / stop before forced local close]),
      ([Recording waiter], [One], [Wait timeout/death clears only the waiter; finalization continues]),
    ))
    #points(
      [The connect timer includes DNS, TCP and TLS. Native connect/handshake limits receive its remainder. DNS worker lifetime ends under the connection budget; pending request expiry discards unused preparation. Idle read is active only while demand is outstanding, rather than while application code holds a chunk.],
      [Native TCP/TLS send_timeout and send_timeout_close use startup idle timeout. Request-owner expiry independently bounds fresh and reused buffered uploads. H1 expiry closes its exclusive connection; H2 stream cancellation preserves healthy siblings. No bound is claimed when the corresponding option is Infinity.],
    )
    #facts(([Boundary], [Effect committed or observed], [Failure and uncertainty]), (
      ([Validated invocation], [No network action], [Invalid/refused/capacity failure has NotSent]),
      ([Resolution admitted], [Address set authorized; no HTTP submission], [Connecting failure remains NotSent]),
      ([Gun request invoked], [One asynchronous transport request issued], [Every later live failure is MaybeSent; return proves no socket write or remote receipt]),
      ([Final head admitted], [Status and headers observed], [Streaming caller owns head; collection failures retain redacted headers/status]),
      ([HTTP EOF], [Transport lease may release], [Application consumption and capture finalization may remain incomplete]),
      ([Capture acknowledgment], [Writer fragment and close completed], [No fsync or power-loss persistence established]),
      ([Atomic link/rename], [Completed cassette visible at destination], [Abort cannot undo commit; a racing interruption can leave visible publication despite uncertain finish acknowledgment]),
      ([Observation delivery], [Best-effort notification], [No HTTP/capture authority or durable history]),
    ))
    #points(
      [These are admission/storage and scheduling guarantees. User callback allocations, filesystem blocking, native buffers and VM scheduling remain outside them. Native timers do not create real-time execution guarantees.],
    )
  ])

  #section(title: "Collection batching and failures", lead: "Preserve per-position outcomes and caller-owned retry decisions.", body: [
    #subsection(title: "Collection and overflow", [
      #points(
        [`send` consumes the same body owner as streaming and always closes it. Buffered contains Response(BitArray), trailers, H1/H2/Offline and a truncated flag. Complete bodies concatenate accepted chunks; no UTF-8/JSON assumption is introduced.],
        [Fail overflow closes and returns LimitExceeded(ResponseBodyBytes, limit, observed), with final status and redacted response headers. Truncate closes and returns the first limit bytes, original status/headers, truncated true and empty trailers. It makes no claim to full response completion.],
        [`body.collect` explicitly supplies its own byte bound to an already opened body. Streaming next calls are not cumulatively limited by the collection limit; buffered-byte and time limits still apply.],
      )
      #behavior(title: "Collection overflow preserves the response head", level: "boundary", area: "Buffered collection")[
        #given[the response head has arrived and collection uses Fail]
        #when[accepted response bytes exceed the collection limit]
        #then[collection fails and closes the body]
        #then[the failure retains status and redacted response headers]
      ]
    ])
    #subsection(title: "Bounded batch lifecycle", [
      #points(
        [Batch validates input count and concurrency before scheduler startup. Workers own one request's open/read/close lifecycle. At most requested concurrency workers run. Caller death kills its workers; body ownership then releases their HTTP resources.],
        [Results preserve input order regardless of completion order. One request failure occupies only its position. Worker crash conservatively yields RequestFailed(UnknownTransport)/MaybeSent at that position and releases its worker slot.],
        [One shared atomic counter charges retained body bytes before collection keeps a chunk. Overflow fails the crossing response. Once crossed, positions not yet sent fail with BatchBytes/NotSent. Existing workers can settle independently. The counter is monotonic and does not refund failed-response bytes.],
        [The 64 MiB budget measures charged body bytes, not headers, input values, worker stacks or transient concatenation copies. The rejected crossing chunk has already been delivered to a worker. It is not a whole-batch VM allocation certificate.],
      )
    ])
    #subsection(title: "Failure meaning and serialization", [
      #points(
        [#term("term-submission-evidence") is NotSent before the live Gun request call and MaybeSent afterward. Offline scripted failures retain recorded evidence while their telemetry mode is Offline. Closing is local cancellation and never remote rollback.],
      )
      #facts(([Closed Kind], [Reasons grouped here], [Caller action]), (
        ([InvalidInput], [InvalidRequest], [Correct input or settings]),
        ([Refused], [DestinationRejected; ViewDestinationRequired], [Choose authorized destination]),
        ([Unavailable], [ClientClosed; AdmissionFull; PoolTimeout; RecordingClosed], [May retry if evidence permits]),
        ([Network], [ResolutionFailed; ConnectionFailed; RequestFailed], [Inspect typed transport cause and evidence]),
        ([TimedOut], [ConnectTimeout; DeadlineExceeded; IdleTimeout], [Retry only under evidence/idempotency policy]),
        ([TooLarge], [Measured LimitExceeded], [Change bounds or consumption policy]),
        ([CancelledLocally], [Closed; Cancelled], [Reconcile application intent]),
        ([Misuse], [ReadConflict; WrongOwner], [Correct ownership/concurrency]),
        ([Playback], [PlaybackMismatch; PlaybackExhausted], [Correct explicit fixture]),
      ))
      #points(
        [Only Unavailable, Network and TimedOut are retryable through `is_retryable`. NotSent permits another attempt; MaybeSent requires caller-declared idempotency. This helper does not schedule retries, interpret Retry-After or validate business idempotency.],
        [Known transport categories include name resolution, refused/reset/closed/draining connections, certificate/TLS rejection, protocol, dependency header limit, timeout and unexpected protocol. Unknown terms remain UnknownTransport without exposing raw dependency text or stack traces.],
        [`name` is a stable machine identifier; `describe` omits free-form request/config/fixture data. Failure never contains request headers, URL, query or body. Collection may retain response headers after redaction; serialization stores those retained headers. Explicit `with_headers` authors safe data and does not automatically apply a redaction policy.],
        [`to_json` and `decoder` round-trip typed diagnostic data and evidence. Required measured sizes stay distinct from unavailable parser measurements. StartError, request Failure, cassette I/O, RecordError and FinishError remain separate boundaries.],
      )
    ])
  ])

  #section(title: "Playback cassettes and redaction", lead: "Offline sequence ownership and one current data format.", body: [
    #subsection(title: "Playback matching and cursor", [
      #points(
        [`testing.playback` validates complete configuration, whole-byte request/chunk bodies, final statuses 200–599 and estimated script size before starting. It creates a #term("term-playback-session") with one global admission-ordered cursor. Concurrency does not define a reusable first-match lookup.],
        [Exact match keys apply configured redaction to both expected and actual requests. Host and header names become lowercase, empty path becomes slash, ignored headers disappear and remaining headers sort by name while duplicate-name order remains. Method, URI fields and bytes otherwise remain exact.],
        [An explicit custom matcher receives these normalized forms. It owns only equality; common validation, lifetime and response admission still run. A mismatch reports the zero-based position and consumes nothing. Exhaustion fails without network fallback. Custom callbacks are trusted code and can block the pool.],
        [Offline requests skip destination resolution/address authorization and open no network socket. Required-view selection still applies. Bodies pass the same post-delivery header/byte admission and collection logic with negotiated protocol Offline.],
      )
      #behavior(title: "Playback mismatch preserves the next exchange", level: "boundary", area: "Playback matching")[
        #given[an offline session has an unused next exchange]
        #when[the request does not match it]
        #then[the request fails with the current position]
        #then[the next matching request consumes that same exchange]
      ]
    ])
    #subsection(title: "Cassette schema and bounded file input", [
      #points(
        [A #term("term-cassette") has marker `http_gun: 2` and an exchanges array. Each exchange has method, URL, ordered header pairs and body; its reply is reject(failure) or response(status, headers, chunks, ending). Ending is finished(trailers), aborted(failure) or abandoned.],
        [Whole bytes encode as text when valid UTF-8, otherwise base64. Invalid required fields, methods/URLs, header-pair shapes, base64 or final status produce Corrupt. Another integer format marker produces UnsupportedVersion. There is one current decoder and no compatibility fallback. #adr(5)],
        [Required fields are decoded; unknown extra JSON fields are not a closed-object rejection contract. If both text and base64 are present, the text branch has precedence. Parse does not perform the playback script-data budget check until playback startup.],
        [`parse(text, max_bytes)` checks encoded string size before JSON decoding. `load(path, max_bytes)` uses raw reads of at most max_bytes plus one without read-ahead. A negative file limit clamps to zero. Empty/non-UTF-8/malformed data is corrupt; missing and I/O failures remain typed.],
      )
    ])
    #subsection(title: "Secret ownership and whole-body rewriting", [
      #points(
        [#term("term-redaction") always removes authorization, proxy-authorization, cookie, set-cookie, x-api-key, api-key and x-goog-api-key. Added header names are case-insensitive and affect stored request/response headers, trailers and collected failure headers.],
        [Query redaction matches exact percent-decoded parameter names, treating plus as space. Listed names keep their original encoded spelling with value REDACTED. Parameter order and all unselected query bytes remain exact.],
        [A body hook rewrites each request body and each response body as a whole. Recording holds response chunks within its capture budget then stores one rewritten chunk, so split secrets are visible to that hook. A later hook replaces the earlier one. The live request/response delivery remains unchanged.],
        [Matching applies the same hook to expected and incoming request values. A recorder can redact a request before storage and matching can redact it again; callback authors therefore supply stable repeatable rewriting. Callbacks own their execution time, allocations and retained captures. There is no general secret detector or callback sandbox.],
        [Unlisted headers, query parameters and body data remain in fixtures. Safe logging of failures and observations does not imply that user-supplied fixtures, callback state, native VM crash data or arbitrary application logs contain no secrets.],
      )
    ])
  ])

  #section(title: "Recording and filesystem publication", lead: "Capture completion is separate from HTTP completion.", body: [
    #subsection(title: "Reservation order and acknowledged writer", [
      #points(
        [`cassette.record` validates configuration and capture options, creates one exclusive sibling staging directory and applies mode 0700 before request data is stored. It then starts the recorder and live pool. Failed pool startup discards the recorder's staging area.],
        [Each #term("term-capture-reservation") receives a zero-based position before live execution. Concurrent completion writes separate exchange spool files; final assembly follows reservation order. Capacity/policy/connect/open failures can be recorded as reject outcomes. Refusals preceding capture reservation are not stored exchanges.],
        [The recorder has one active writer and an admitted job queue. Request fragment reservation and each head/chunk/terminal fragment are budgeted before enqueue. Body owners wait for capture acknowledgment before delivering successful data or demanding more; capture limits also bound held whole-body redaction input.],
        [Acknowledgment follows completed normal write and file close. There is no delayed-write buffer or fsync guarantee. Capture failure detaches recording from HTTP; live outcomes continue independently. A recorder closed by accepted finish refuses new requests with RecordingClosed; a broken capture may let live requests continue uncaptured.],
        [A body with pending capture acknowledgment after HTTP EOF can retain its timer until capture settles. Deadline may separately abandon capture without retrospectively changing completed HTTP. Capture is not an eager HTTP reader and cannot drain an unread response to make finish succeed.],
      )
    ])
    #subsection(title: "Finish waiter and publication commit", [
      #points(
        [Nonpositive finish waits request immediate completion. Active unfinished capture returns Busy without closing new reservations. Positive waits close reservations, wait for all streams/jobs and initiate final assembly. Only one waiter is accepted; concurrent contention returns Busy.],
        [WaitTimeout or waiting-process death removes only the waiter. Closing/Sealing continues; a later finish sees the final result. The recorder's creator death interrupts unfinished capture. Normal live-client stop does not itself discard completed capture; abnormal client loss interrupts it.],
        [Sealing builds a complete JSON file beside the destination from bounded spool reads. RefuseExisting publishes by hard link; ReplaceExisting publishes by rename. No check-then-overwrite fallback exists. AlreadyExists and other I/O causes remain explicit. #adr(5)],
        [#term("term-publication") is atomic on a filesystem supporting the selected link/rename operations. Cross-filesystem publication and power-loss survival are not promised. Published data is complete; interrupted staging data is not a replayable cassette.],
        [Abort is local to capture and leaves the live client usable. It cannot undo an already committed filesystem operation. The actor only observes publication through writer acknowledgment, so an abort/owner-loss race after atomic commit can leave a visible file while finish reports interruption. No stronger transaction barrier is inferred.],
      )
      #behavior(title: "Finish wait expiry preserves finalization", level: "boundary", area: "Recording finalization")[
        #given[accepted finalization is waiting for existing exchanges]
        #when[the finish wait expires]
        #then[the caller receives WaitTimeout]
        #then[finalization continues without accepting new reservations]
        #then[a later finish can observe its final outcome]
      ]
    ])
    #subsection(title: "Failure cleanup and operational limits", [
      #points(
        [Write failure, capture overflow, abandoned reservation, failed publication, abort, owner loss and recorder crash trigger staging cleanup. A janitor monitors recorder death. Cleanup kills the active writer and waits up to 200 milliseconds before allowing a separate cleaner to wait for its exit.],
        [The actual removal primitive deletes only direct files or empty child directories, then the staging directory. It never recursively traverses unknown nested data. Removal errors are ignored. Unremovable entries, a blocked writer and VM termination can leave data behind. The cleanup promise strength is unresolved in Pending updates. #adr(10)],
        [file_streams supplies explicit Raw/Exclusive writes and bounded raw reads. simplifile supplies permission, hard-link, rename and file deletion. Scope helpers close handles on exceptions before re-raising. When both normal operation and close fail, the primary operation failure takes precedence.],
        [Runtime leftovers named with the destination's `.http-gun-` staging suffix are safe to remove after the writer/recorder no longer owns them. Applications decide artifact retention and privacy. No directory sync or remote object-store publication port exists.],
      )
    ])
  ])

  #section(title: "Observation and composition ports", lead: "Identity and milestones carry facts without granting authority.", body: [
    #subsection(title: "Milestones and delivery selection", [
      #points(
        [Lifecycle event path is `http_gun/lifecycle`. Its typed metadata carries #term("term-request-id"), optional caller correlation, optional client label, Live/Recorded/Offline mode and a milestone. Timing is monotonic VM-local milliseconds.],
      )
      #facts(([Milestone], [Authority], [Observed fact]), (
        ([AdmissionEntered], [Pool], [Validated invocation received before admission/capture reservation]),
        ([AdmissionWaiting], [Pool], [Invocation entered finite waiting/preparation work]),
        ([AdmissionGranted], [Pool], [Eligible lease selected or offline exchange matched]),
        ([GunCallReturned], [Body owner], [Asynchronous Gun API returned; no transport write/receipt established]),
        ([ResponseHeaders(status)], [Body owner], [Final head passed admission]),
        ([HttpTerminated(outcome)], [Body owner or rejecting pool], [Complete, LocallyCancelled, DeadlineExpired or Failed]),
      ))
      #points(
        [No lifecycle event contains URL, query, header, body, credentials or raw dependency terms. There are no per-chunk events by default. Labels and correlation are application-supplied metadata and must themselves be safe.],
        [Default Emit calls `sinal.emit` and follows application routing. Without a route, user handlers run synchronously inside pool/body actors and can delay requests and timers. A configured direct forwarder isolates delivery; full/unavailable forwarding is best effort and its result is discarded. Silent emits nothing. #adr(6)],
        [HTTP Gun creates no collector, retained timeline, forwarding mailbox or export queue. Applications supervise and bound forwarders and history. Observation arrival order across pool/body processes is not a request-order guarantee. Abrupt actor/VM death can omit terminal notification.],
        [Events are unsuitable for effect correctness or retry permission. Complete means HTTP EOF rather than application consumption or successful publication. Offline never emits a live Gun submission milestone. Recording persistence is a separate authority.],
      )
    ])
    #subsection(title: "Caller and extension obligations", [
      #points(
        [A library receiving a view reads `http_gun.correlation` and copies it into its own event vocabulary. It preserves caller settings. A library owning a private client labels it with the library name; silence is an explicit alternative. Application startup owns route installation and removal.],
        [Resolver, body redactor, playback matcher and scoped response callback are the variable-behavior ports. Common client admission, failure evidence and actor cleanup remain local to HTTP Gun. Callback authors own finite captured state and resources they spawn; custom matcher/redactor execution is not isolated by a timer.],
        [Provider adapters own authentication, request encoding, expected status/media type, cumulative semantic response bounds, SSE/provider framing and outcome reduction. MCP clients own MCP correlation/protocol semantics. OIDC clients own URL/trust restrictions and identity validation. No shared retry/runtime/error/durability abstraction is introduced.],
        [Body transfer has no public operation. An async consumer opens inside the process that will read. Introducing transfer would require revocation, in-flight read, death and cancellation semantics; it is not inferred from body copying.],
      )
    ])
  ])

  #section(title: "Foreign boundary and dependency upgrades", lead: "Translate native operations without moving policy out of Gleam.", body: [
    #facts(([Bridge], [Allowed responsibility], [Upgrade-sensitive contract]), (
      ([Gun bindings], [Start/open/request/update_flow/cancel/close, supported info lookup and terminal event forwarding], [Asynchronous request submission; protocol choice; no replay; H1 state_name inspection; terminal cause sent to the original owner before Gun exits]),
      ([Event conversion], [Up/down/head/data/trailers/inform/upgrade/settings conversion to typed events], [Structured error shapes; H2 pseudo-header counting; initial capacity changes]),
      ([Runtime primitives], [Monotonic time, atomic batch counter, exception-safe scopes and address/DNS conversion], [VM-local clocks; whole-byte/IP conversion; narrow trusted boundaries]),
      ([Filesystem primitives], [Unique directory candidate, empty-directory/direct-entry cleanup], [Exclusive creation remains in Gleam; nonrecursive best-effort removal]),
    ))
    #points(
      [No handwritten Erlang pool, body server, recorder server, DNS admission server or protocol parser exists. Native exception classification returns bounded recognized causes and UnknownTransport. Internal module visibility is documentation organization rather than an import-security boundary; opaque capability construction and actors enforce authority.],
      [Gun range is 2.6.0 inclusive to 2.7.0 exclusive. Cowlib range is 2.20.0 inclusive to 2.21.0 exclusive. Patch ranges permit security updates while minor changes require deliberate audit. The committed manifest selects the tested minimum; latest-patch isolated resolution exercises the other end. #adr(7)],
      [Undocumented assumptions are H1 `gun:info` state_name connected; reason terms inside gun_error/gun_down; Gun terminal event callback before process exit; source-reviewed request return timing; H2 max_headers including status; and test-only cow_http2/cow_hpack calls. Unknown state rejects reuse; unknown reasons lose precision rather than becoming safe-retry evidence.],
      [Widening a range requires inspecting each assumption, updating decoding only under an accepted contract, running minimum/latest full gates and qualifying public consumers. A changed test helper API can break H2 evidence and must not be mistaken for a production protocol change. `docs/DEPENDENCY-UPGRADES.md` holds the operational procedure.],
    )
  ])

  #section(title: "Validation and retained capability scope", lead: "Observable tests establish boundaries; preserved intent remains visible.", body: [
    #subsection(title: "Evidence and tests by boundary", [
      #facts(([Boundary], [Executable evidence], [What it establishes]), (
        ([Ordinary and API adoption], [`examples/ordinary`, README tests, type rejection in dev/consumers], [Common calls, advanced views, caller errors, opaque capability use through public imports]),
        ([HTTP/H1/TLS], [test request/stream/reuse/trust/destination wire suites; local Erlang servers], [Binary/status/header/trailer fidelity, reuse, deadlines, policy, write cleanup]),
        ([H2], [Controlled H2 server plus dev/nghttpd], [Actual negotiation/shared socket, peer capacity, cancellation and GOAWAY boundaries]),
        ([Lifecycle and async], [Timeout/pool/adoption suites; examples/async], [Read conflicts, owner death, supervision, local wait, blocked sink and cancellation]),
        ([Cassette and capture], [Cassette/recording/fault suites], [Strict order, byte codec, terminal failures, redaction, capture independence and atomic publication]),
        ([Finite resources], [Batch/recording/load benchmarks and dev boundary checks], [Admitted counters, captured budgets and observed scaling under stated environment]),
        ([Dependency boundary], [FFI warning build, min/latest CI, stdlib boundary checks], [Supported source compatibility and native helper assumptions]),
      ))
      #points(
        [Gun/Cowlib source and protocol behavior are authoritative for transport mechanics. Dream, ReqCassette, Gleam HTTPc, Mint and Finch supply scoped scenarios and comparison methods. They are not complete parity oracles. Attribution, hashes and raw receipts remain with executable evidence. #adr(1)],
        [Source inspection, inspired tests, faithful ports and differential execution are distinct evidence classes. Real H2 sharing cannot be proven by two H1 sockets or script playback. Performance samples establish only their workload/runtime measurements.],
        [The fast/full gate, runtime matrix, ordinary and async consumers, isolated downstream selection and local test-server procedures remain in `docs/TESTING.md`. Normal gates use local HTTP/TLS/H2, temporary files and no provider credentials.],
      )
    ])
    #subsection(title: "Retained extensions and explicit exclusions", [
      #points(
        [Streamed uploads, redirect following, decompression, proxies/mTLS, cookie/cache adapters and generic SSE framing remain intended extensions with their contracts in Pending updates. The present facade returns buffered uploads, redirect statuses and encoded response bytes directly. #adr(9)],
        [WebSocket, HTTP/3, server-framework, automatic application retry, transfer recovery and agent continuation remain outside package ownership. Gun's broader capability does not expand this facade implicitly.],
        [A broader extension must preserve process/body ownership, address checks on new routes, one-attempt evidence, finite admission and independently reported capture. Cross-package consumers prove the public extension from their own package before facade acceptance.],
      )
    ])
  ])
]
