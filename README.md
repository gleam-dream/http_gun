# HTTP Gun

HTTP Gun is an independent Gleam/Erlang HTTP client on Gun. It provides a small typed API, owned streaming, bounded collection, managed H1/H2 connections, strict playback and live recording. The client is under implementation; remaining work concerns pool/lifecycle races, recording persistence and practical load validation.

Gun/Cowlib own wire parsing. HTTP Gun owns application limits and client behavior. It inherits the dependencies' parser and transport behavior and does not promise a whole-process memory ceiling. The owner selected this scope in [ADR 0001](docs/adr/0001-managed-client-scope.md).

The package uses standard `gleam/http/request.Request(BitArray)` and `gleam/http/response.Response(body)` values. It has no production dependency on LLM Wire or another Gleam Dream package. HTTP status codes remain response data. It neither retries requests nor follows redirects nor decompresses bodies.

The active [reliability completion plan](docs/implementation/reliability/plan.md) orders the remaining work and defines its acceptance checks. Resume work from its [wave tracker](docs/implementation/reliability/wave-tracker.md).

## Ordinary use

```gleam
import gleam/bit_array
import gleam/http/request
import http_gun

pub fn main() {
  let assert Ok(client) = http_gun.start(http_gun.settings())
  let assert Ok(request) = request.to("http://localhost:8080/data")
  let request = request.set_body(request, bit_array.from_string(""))
  let result = http_gun.send(client, request)
  let _ = http_gun.stop(client)
  result
}
```

`send` collects the same body consumed by `open` and `next`. Its result retains the standard response, trailers, and protocol/delivery information. A finite collection limit always applies. Failure or early exit closes the body.

Use `open` to obtain `Opened(Response(Body), Info)`. `next(body, wait_ms)` returns `Chunk(bytes)`, `End(trailers, evidence)`, or a typed `Failure`. The process that opened a body owns consumption. Copying a handle shares state; it does not transfer ownership. A competing read while a read is pending returns `ReadConflict`; another consuming process otherwise receives `WrongOwner`. `close` is idempotent and means local cleanup. It does not acknowledge server cancellation.

Use `with_response(client, request, fn(opened) { ... })` for scoped consumption. It closes after normal return and supported Erlang exceptions and preserves the callback's own value/error type inside the outer Result. A local read wait timeout keeps the exchange and outstanding credit intact. An overall exchange deadline is terminal.

## Configuration and ownership

`settings()` constructs a pure record. Update its nested records before `start`. Validation precedes client startup. Each client owns separate pools and fixed trust/protocol settings; incompatible client policies cannot share a connection. `child(settings)` returns a standard `gleam/otp/supervision` child specification. Restarting creates a new capability; previously distributed handles remain closed.

The defaults are H1 only, verified system trust, 16 origins, 16 connections, four connections per origin, 128 active body owners, 100 streams per H2 connection, and 128 queued admissions. H1 uses exclusive leases. H2 reuses available stream capacity before opening another connection. RequireHttp2 uses TLS ALPN for HTTPS and prior knowledge for explicit plaintext HTTP; PreferHttp2 falls back to H1 on HTTPS negotiation and uses H1 for plaintext endpoints.

The default overall/connect/head/idle/shutdown budgets are 30s/5s/10s/30s/5s. Idle includes a deliberately stalled consumer. `stop` rejects new work and drains up to the shutdown budget. Gun retry is zero. A failure after submission preserves `MayHaveBeenSent`; no delivery field proves remote execution or rollback.

Default byte limits are 1 MiB request body, 16 KiB admitted head/trailers, 64 KiB admitted chunk, 128 KiB retained body queue, 64 MiB total response, and 8 MiB buffered collection. Header count is 100; informational count is eight. Removing the optional total-transfer cap does not remove the other limits. See [BOUNDS.md](BOUNDS.md) for the exact scope of application limits and inherited transport behavior.

## Startup-time live, record, or playback selection

The [ordinary consumer](examples/ordinary/src/http_gun_consumer.gleam) supplies one explicit startup switch and retains every owned handle. Execution never reads an environment variable or process dictionary to select a cassette.

- Live: `http_gun.start(settings)`.
- Playback: `cassette.load(path, max_bytes)` then `cassette.playback(value, settings)`.
- Recording: start a live client, then `cassette.record(live, path, options)`. The result contains a Client accepted by ordinary calls and a Recording for `cassette.finish`.

Recording borrows the live client. Stop the recording client and the live client separately. Finish refuses while exchanges are active; consume or close them first. A successful repeated finish returns the same path. Existing destinations are refused unless `ReplaceExisting` was explicitly selected.

HTTP completion and capture persistence are separate results. A capture failure is reported by `finish` with its available delivery evidence; it does not turn an already received HTTP response into a failed remote operation. Callers must inspect finish. Incremental capture uses a private temporary directory and a finite session budget. Finalization assembles a bounded document, then publishes with an atomic hard link for no-replace or rename for explicit replacement. This provides process-crash visibility semantics on the same filesystem; it does not promise fsync or power-loss durability.

Capture acknowledgements hold back body consumption without blocking the body owner's deadline and cleanup messages. A failed writer stops further capture; a local read timeout retains admitted HTTP bytes. Reads, headers, chunks and trailers check the applicable monotonic deadlines before admission. A late message cannot revive an expired operation or phase. If HTTP has already completed, the overall deadline abandons stalled capture and preserves the HTTP result. Completed HTTP also survives orderly or abrupt live-client loss; cancellation before headers replays without an invented response. Losing the recorder process leaves the borrowed live transport usable. Body-owner loss and aggregate pending capture have real regressions. Recorder control during filesystem work and concurrent finalization remain release work; see [the acceptance inventory](docs/implementation/reliability/check-manifest.json).

Offline response diagnostics use `NotNegotiated` and connection id zero; playback does not claim a socket or negotiated protocol. The version 1 JSON envelope stores ordered request identities, encoded byte lengths/base64, final heads, chunks, trailers, and complete/failed/locally-cancelled tags. Failures before final headers include explicit submission evidence. Missing, malformed, oversized, mismatched, and exhausted fixtures fail without live fallback. Concurrent admissions consume a shared sequence in admission order; use separate sessions for independently ordered flows. Legacy LLM v1 fixtures are incompatible and have no implicit converter.

Authorization, proxy authorization, Cookie, and Set-Cookie metadata are removed by default. Meaningful remaining headers participate in matching. Query keys may be removed explicitly. Bodies and queries can contain secrets. `ReplaceBodies` substitutes the entire body under a finite input limit, so split-token content cannot leak through per-chunk replacement. It is deliberately coarse; selective streaming redaction is not implemented. KeepBodies records exact admitted bytes. Treat fixtures as application data.

## Development environment

The development environment is managed with Nix flakes (`flake.nix`), providing Gleam 1.18.1, Erlang/OTP 29, Elixir 1.18.5, and rebar3, with multi-language formatting via `treefmt` (`nix fmt`) and Git hooks managed by `lefthook`.

```sh
# Enter development shell
nix develop
# or with direnv:
direnv allow

# Install pre-commit hooks
lefthook install

# Format repository (Gleam, Elixir, Nix, Markdown)
nix fmt

# Check flake and formatting
nix flake check
```

## Validation

Provision the locked dependencies once with `./dev/env gleam deps download`. Normal test servers are isolated loopback servers and use the committed local test CA. No provider credentials or live HTTP endpoints are used by the gates.

```sh
./dev/env sh dev/gate fast
./dev/env sh dev/gate full
```

Fast runs formatting, check/build/tests, FFI compilation with warnings as errors, and production boundary/oracle-ledger/acceptance-inventory checks. Full additionally runs isolated positive/negative consumers, the public LLM integration, the concurrency experiment, and readiness for the managed-client scope. Dependency patch probes are archived and are not release checks. Readiness requires a current source fingerprint for the executed components as well as covered acceptance checks. The latter currently fails; [CAPABILITIES.md](CAPABILITIES.md) distinguishes required unfinished work from follow-on scope.

[ORACLES.md](ORACLES.md) records provenance. [MIGRATION.md](MIGRATION.md) scopes future LLM Wire adoption. [docs/VALIDATION.md](docs/VALIDATION.md) records exact outcomes and practical limits. The default development shell uses Gleam 1.18.1, OTP 29, Elixir 1.18.5, Gun 2.6.0, and Cowlib 2.20.0, with dedicated shells `.#otp28` and `.#otp27` retained for compatibility checks. Earlier local full-gate components and concurrency measurements ran on OTP 27 and 28; current receipts and remaining checks are listed in the validation record. A production support matrix is not yet accepted.
