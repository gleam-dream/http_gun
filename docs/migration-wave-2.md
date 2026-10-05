# Wave 2 migration

## Follow-up: correlation

HTTPGUN-R8, correlation part. The `correlation` metadata key now holds the
caller's `sinal/correlation.Correlation`, the value every gleam-dream package
writes under that key (ecosystem decision 3). HTTP Gun's own per-invocation
identity stays under `request_id`. Routed emission, the rest of R8, is left to
wave 3.

### Changed public items

`http_gun.with_correlation` takes a Sinal correlation:

```gleam
// Before
let id = telemetry.new_id()
let client = http_gun.with_correlation(shared, id)

// After
import sinal/correlation
let assert Ok(order) = correlation.from_string(order_id) // or correlation.unique()
let client = http_gun.with_correlation(shared, order)
```

`telemetry.Metadata.correlation` is `Option(Correlation)`, encoded by
`correlation.field()`; the key is omitted when the view carries none:

```gleam
// Before
Metadata(request_id: Id, correlation: Option(Id), mode:, milestone:)

// After
Metadata(request_id: RequestId, correlation: Option(Correlation), mode:, milestone:)
```

`telemetry.Id` is renamed `telemetry.RequestId`. Only HTTP Gun creates it;
callers compare it by equality to group one invocation's milestones.

```gleam
// Before
fn group(id: telemetry.Id) { .. }

// After
fn group(id: telemetry.RequestId) { .. }
```

`telemetry.new_id()` is removed. A join table from an app key to an HTTP Gun
id is no longer needed: pass the app's own correlation and match
`metadata.correlation` against it.

```gleam
// Before
let id = telemetry.new_id()
links = dict.insert(links, id, order_id)
// in the handler: dict.get(links, metadata.correlation)

// After
let client = http_gun.with_correlation(shared, order)
// in the handler: metadata.correlation == Some(order)
```

### Dependents

No sibling package (`llm_wire`, `warden`, `fabric`, `relay`, `grind`, `saga`,
`json_blueprint`) calls `with_correlation`, `telemetry.new_id` or names
`telemetry.Id` in `src`, `test`, `integrations` or `consumers`. The apps under
`oversight/apps` are affected:

| App            | Call sites                                                                                                                                                                                          |
| -------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| checkout       | `src/checkout/app.gleam:124` (`with_correlation`); `src/checkout/telemetry.gleam:40,56,63,100,144` (`Id`, `new_id`, order-to-id table); module docs `telemetry.gleam:7-8`, `gateway.gleam:4`        |
| extractor      | `src/extractor/jobs.gleam:98,99` (`with_correlation`); `src/extractor/telemetry.gleam:41,48,57,150,151,185,214` (`Id`, `new_id`, id-to-document table)                                              |
| research_agent | `src/research_agent/remote.gleam:38,40` (`new_id`, `with_correlation`); `src/research_agent/telemetry.gleam:12,42,58,65,76,95,296,344` (`Id`, id-to-research table, `m.correlation`)                |
| sso_portal     | `src/sso_portal/web.gleam:225` (`with_correlation`); `src/sso_portal/telemetry.gleam:32,38,54,55,63,64,112,147-149` (`Id`, `new_id`, pid-to-id links)                                               |
| support_desk   | `src/support_desk/desk.gleam:47,139,190` (`Id`, `new_id`, `with_correlation`); `src/support_desk/telemetry.gleam:14,75,76,81,106,292,299` (`Id`, id-to-ticket table, `m.correlation`)               |
| tool_hub       | `src/tool_hub/assistant.gleam:44,97,101,123` (`Id`, `with_correlation`, `new_id`); `src/tool_hub/telemetry.gleam:6,30,57,62,144` (`Id`, run-to-id links); `test/tool_hub_test.gleam:428` (`new_id`) |
| webhooks       | `src/webhooks/delivery.gleam:44,117,121` (`Id`, `new_id`, `with_correlation`); `src/webhooks/telemetry.gleam:113,129,138,178,284,304` (`Id`, id-to-delivery table, `m.correlation`)                 |

Each app can drop its HTTP Gun join table and pass the `Correlation` it
already uses for the unit of work (order, document, research, request,
ticket, run or delivery).
