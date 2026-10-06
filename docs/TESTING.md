# Local validation and operational evidence

## Package gates

```sh
./dev/env sh dev/gate fast
./dev/env sh dev/gate full
sh dev/matrix
```

- `dev/env` enters this repository's pinned Nix shell. `dev/gate` builds an isolated validation copy unless already inside that gate. Normal gates do not consume sibling working copies.
- Fast checks formatting, Gleam check/build/tests, native warnings and ownership/dependency boundaries. Full adds stdlib edge versions, ordinary/async consumers, real nghttpd HTTP/2, shared batch budgets, recording and load observations.
- The runtime matrix qualifies each selected shell in isolation. Measurements report their actual runtime, workload and capacity. Passing tests establish their named observations rather than a whole-stack memory bound.

## Public consumers and downstream selection

- [Ordinary consumer](../examples/ordinary/src/http_gun_consumer.gleam) compiles as its own package and demonstrates common calls, advanced views, caller error types, observation routes and record/replay.
- [Async recipe](../examples/async/README.md) owns bounded application jobs, worker lifetime, synchronous sinks and cancellation. [Comparison harness](../examples/comparison/README.md) keeps benchmark differences explicit.
- `dev/consumers` includes public-import and opaque-capability checks. `dev/check_downstream.py` performs explicitly selected isolated LLM Wire qualification and records source identity. Inspect that command's arguments before use; it is deliberately outside the ordinary gate.
- Historical archived consumers prove only their recorded revisions. Current downstream compatibility requires selecting the current source and checking originals remain unchanged. No normal gate should silently modify a sibling checkout.

## Local fixtures and evidence

- Tests use local Erlang HTTP/H2/TLS servers and [test certificates](../test/fixtures/README.md). `dev/ip-fixture` generates the IP-SAN case. Loopback access is explicitly enabled by each local test client.
- `dev/nghttpd.py` uses the development nghttpd package for real peer-capacity and trailer checks. Local interop owns no provider semantics or public Internet requirement.
- `build/evidence` contains current runtime outputs. `docs/history/evidence` preserves raw source/hash/receipt/log inputs from earlier qualification, including Dream comparison, Sinal source selection and destination/Warden scenarios. These retained paths are evidence storage; they do not carry a competing design contract or current completion diary.
- `NOTICE`, dependency licenses and fixture attribution remain authoritative for source reuse. Git retains retired prose reports; [ADRs](adr/0001-gleam-owns-exchange-state.md) record material decisions.

## Recording operation

- Stop the HTTP client separately from finishing or aborting capture. A finish wait timeout does not abort capture. Another finish can observe the eventual result; an abort cannot remove an already published file.
- Staging directories use the destination's `.http-gun-` suffix and contain sensitive exact data outside the selected redaction. Cleanup is attempted on failures and recorder loss. The current primitive ignores removal failures and can leave data while a writer is blocked; inspect and remove abandoned staging data after its owners have exited.
- Successful publication guarantees a complete visible fixture on the destination filesystem. It does not guarantee survival after power loss. [The unresolved cleanup decision](adr/0010-consolidate-design-and-expose-cleanup-gap.md) records the stronger public-promise tension.
- `dev/convert_cassette.py` is an explicit offline schema-1-to-2 conversion tool. Runtime playback retains one current decoder and never migrates or rerecords automatically.
