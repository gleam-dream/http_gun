# Wave 4 migration

Wave 4 makes two changes:

- every timeout, deadline and wait in the public API takes a
  `gleam/time/duration.Duration` (package `gleam_time`, `>= 1.11.0 and < 2.0.0`),
  and an unbounded timeout is the explicit `config.Infinity`. No public
  signature takes milliseconds as an `Int`, and no converted name ends in `_ms`;
- a destination policy has a plaintext rule, `destination.with_plaintext`,
  decided against the resolved addresses (LLM-R10).

The defaults are unchanged. HTTP Gun still keeps whole milliseconds inside: a
sub-millisecond remainder rounds away from zero, so a positive duration stays
positive and a negative one stays negative. A dependent that imports
`gleam/time/duration` adds `gleam_time = ">= 1.11.0 and < 2.0.0"` to its own
`gleam.toml`.

Contents: [config](#http_gunconfig) · [http_gun](#http_gun) ·
[body](#http_gunbody) · [deadline](#http_gundeadline) ·
[cassette](#http_guncassette) · [destination](#http_gundestination) ·
[dependents](#dependents)

## `http_gun/config`

| Before | After |
| --- | --- |
| `Timeout { Milliseconds(Int) Infinity }` | `Timeout { After(Duration) Infinity }` |
| `with_connect_timeout(config, milliseconds: Int)` | `with_connect_timeout(config, timeout: Duration)` |
| `with_pool_timeout(config, milliseconds: Int)` | `with_pool_timeout(config, timeout: Duration)` |
| `with_request_timeout(config, Milliseconds(ms))` | `with_request_timeout(config, After(duration))` |
| `with_idle_timeout(config, Milliseconds(ms))` | `with_idle_timeout(config, After(duration))` |
| `with_connection_idle_timeout(config, milliseconds: Int)` | `with_connection_idle_timeout(config, timeout: Duration)` |
| `with_shutdown_timeout(config, milliseconds: Int)` | `with_shutdown_timeout(config, timeout: Duration)` |
| `Resolver = fn(String, Int) -> ..` (milliseconds left) | `Resolver = fn(String, Duration) -> ..` (time left) |
| `OutOfRange(setting, value: Int)` for a timeout | `TimeoutOutOfRange(setting, value: Duration)`; `OutOfRange` keeps capacities |

| Setting | Default, unchanged |
| --- | --- |
| connect, including DNS and TLS | `duration.seconds(5)` |
| waiting for a pooled connection | `duration.seconds(5)` |
| request, admission to last byte | `After(duration.seconds(30))` |
| idle read | `After(duration.seconds(30))` |
| idle pooled connection | `duration.seconds(60)` |
| draining on `stop` | `duration.seconds(5)` |

```gleam
// Before
config.default()
|> config.with_request_timeout(config.Milliseconds(10_000))
|> config.with_connect_timeout(1000)
|> config.with_resolver(fn(_host, _remaining_ms) { Ok([address]) })

// After
config.default()
|> config.with_request_timeout(config.After(duration.seconds(10)))
|> config.with_connect_timeout(duration.seconds(1))
|> config.with_resolver(fn(_host, _remaining) { Ok([address]) })
```

A resolver that forwards the time left to an `Int`-taking function converts it
with `duration.to_milliseconds(remaining)`.

## `http_gun`

| Before | After |
| --- | --- |
| `with_timeout(client, config.Milliseconds(ms))` | `with_timeout(client, config.After(duration))` |
| `with_idle_timeout(client, config.Milliseconds(ms))` | `with_idle_timeout(client, config.After(duration))` |

`with_timeout(client, config.Infinity)` and `with_deadline` are unchanged.

## `http_gun/body`

| Before | After |
| --- | --- |
| `next_within(body, wait_ms: Int)` | `next_within(body, wait: Duration)` |

A zero or negative wait still polls once.

## `http_gun/deadline`

| Before | After |
| --- | --- |
| `after(milliseconds: Int) -> Deadline` | `after(budget: Duration) -> Deadline` |
| `remaining_ms(deadline) -> Int` | `remaining(deadline) -> Duration`, whole milliseconds, clamped to zero |

```gleam
// Before
let budget = deadline.after(policy.timeout_ms)
process.receive(control, deadline.remaining_ms(budget))

// After
let budget = deadline.after(policy.timeout)
process.receive(control, duration.to_milliseconds(deadline.remaining(budget)))
```

## `http_gun/cassette`

| Before | After |
| --- | --- |
| `finish(recording, wait_ms: Int)` | `finish(recording, wait: Duration)` |

`finish(recording, duration.milliseconds(0))` still publishes at once or
returns `Busy`.

## `http_gun/destination`

New, additive; the default is unchanged, so webhooks and other plaintext
callers keep working.

| Before | After |
| --- | --- |
| — | `Plaintext { AllowPlaintext PlaintextToLoopbackOnly RequireTls }` |
| — | `with_plaintext(policy, plaintext) -> Policy`; the default is `AllowPlaintext` |
| — | `check_plaintext(policy, address) -> Result(Nil, Rejection)` |
| `Rejection { HostNotAllowed AddressRefused(Class) }` | also `PlaintextRefused(Class)` |

`PlaintextToLoopbackOnly` admits `http://` only when every resolved address is
loopback, including a host name such as `localhost` that resolves to it and a
pooled connection a request would reuse. `RequireTls` refuses every `http://`
request. `https://` is never affected. A refused request fails with
`DestinationRejected(PlaintextRefused(class))`, kind `Refused`, and `NotSent`;
`error.name` reports `destination_rejected.plaintext_<class>`. A view's policy
can tighten the rule, never loosen it. A `case` on `Rejection` gains a
branch.

```gleam
// llm_wire: replace the host-string loopback check
config.default()
|> config.with_destination(
  destination.default()
  |> destination.allow_loopback
  |> destination.with_plaintext(destination.PlaintextToLoopbackOnly),
)
```

## Dependents

### llm_wire

- `internal/http_client.gleam`: `deadline.after(deadlines.overall_timeout_ms)`
  becomes `deadline.after(duration.milliseconds(..))`, or takes a `Duration`
  from llm_wire's own configuration; each `deadline.remaining_ms(budget)`
  becomes `deadline.remaining(budget)`, with `duration.to_milliseconds` where
  an `Int` is still needed (`process.receive`, `overall_timeout_ms`).
- `internal/owner.gleam`: `deadline.remaining_ms(value)` likewise.
- `test/llm_wire_recording_test.gleam`: `cassette.finish(recording, 5000)`
  becomes `cassette.finish(recording, duration.seconds(5))`, and
  `finish(.., 10)` becomes `duration.milliseconds(10)`.
- `test/llm_wire_http_gun_test.gleam`: `http_config.Milliseconds(100)` becomes
  `http_config.After(duration.milliseconds(100))`.
- LLM-R10: drop the host-string loopback check and set
  `destination.with_plaintext(destination.PlaintextToLoopbackOnly)` on the
  client's policy; map `DestinationRejected(PlaintextRefused(_))` to
  llm_wire's own refusal.

### warden

`internal/transport.gleam`:

- `deadline.after(int.max(0, policy.timeout_ms))` becomes
  `deadline.after(duration.milliseconds(policy.timeout_ms))`; `after` already
  treats a negative budget as expired.
- `config.with_request_timeout(config.Milliseconds(timeout))` and
  `with_idle_timeout(config.Milliseconds(timeout))` take
  `config.After(duration.milliseconds(timeout))`;
  `with_connect_timeout(timeout)` and `with_pool_timeout(timeout)` take
  `duration.milliseconds(timeout)`.
- The resolver adapter receives a `Duration`; pass
  `duration.to_milliseconds(remaining)` if warden's own resolver keeps `Int`.

### Apps (oversight `apps/`)

| App | File | Change |
| --- | --- | --- |
| checkout | `src/checkout/gateway.gleam` | `Milliseconds(5000)` to `After(duration.seconds(5))`; `deadline.after(deadline_ms)` to `deadline.after(duration.milliseconds(deadline_ms))` |
| extractor | `src/extractor/clients.gleam` | `Milliseconds(5000)`; `with_connect_timeout(1000)` to `duration.seconds(1)`; resolver's second argument is a `Duration` |
| research_agent | `src/research_agent/app.gleam` | `Milliseconds(5000)` |
| sso_portal | `src/sso_portal/app.gleam`, `src/sso_portal/browser.gleam` | `Milliseconds(5000)`, `Milliseconds(10_000)`; `with_connect_timeout(1000)` |
| support_desk | `src/support_desk/app.gleam` | `Milliseconds(10_000)`; `with_timeout(client, Milliseconds(shop_deadline_ms))` |
| webhooks | `src/webhooks/egress.gleam` | `Milliseconds(settings.deadline_ms)`; a stored `config.Resolver` now takes a `Duration`. Plaintext stays allowed by default |

fabric, sinal and tool_hub use none of the converted signatures.
