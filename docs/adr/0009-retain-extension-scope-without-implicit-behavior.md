# Retain extension scope without implicit request behavior

<a id="adr-0009"></a>

## Decision

- Preserve the original capability inventory: streamed upload; explicit redirect policy; bounded decompression; proxy/client-certificate identity; optional cookie/cache adapters; pure generic SSE framing.
- These capabilities remain native build-pending entries with their admission, ownership and failure requirements. The current core returns redirects/encoded bytes as ordinary data and accepts buffered request bodies.
- WebSocket, HTTP/3, server framework, automatic application retry, transfer recovery and agent continuation remain outside package ownership.

## Rationale and alternatives

- Reducing the design to shipped code would erase explicit retained scope and prevent future implementation from recovering the intended boundaries.
- Pretending an interface exists from Gun's wider capability would invent public acceptance, resource guarantees and consumer evidence.
- Optional policy/storage adapters keep cookie/cache lifetime visible and avoid ambient state. Pure SSE framing can compose with generic bytes while provider semantics remain outside this package.

## Evidence

- Oversight `http-gun-design.md` records the owner's 2026-09-29 assignment and complete capability table. Local docs/DESIGN retains follow-on intent under the Gleam-first restart. `04ef776` establishes the independent core implementation.
- No current public source exposes these extension APIs. This migration carries their contracts forward without authorizing runtime work or creating facade signatures.
