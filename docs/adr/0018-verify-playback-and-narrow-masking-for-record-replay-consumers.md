<a id="adr-0018"></a>

# 0018: Verify playback and narrow masking for record and replay consumers

Date: 2026-11-17
Status: Accepted

## Decision

- A playback session keeps what it refused and the exchanges it has not
  used, and `testing.verify` reports them as a `Verdict`. The caller still
  receives the same failure. A live, recording or stopped client has no
  verdict. A session keeps the first 64 refusals of each kind and counts the
  rest in the verdict's `dropped`, so a test looping on a refused request
  cannot grow it without bound.
- A redaction can keep request headers by allow-list. The allow-list governs
  stored and compared request headers only; `content-type` is always kept,
  and the deny-list applies after it, so a named credential header is still
  removed. Repeated calls add names. Response headers, trailers and failure
  headers keep the deny-list.
- A redaction can rewrite request bodies only. The rewrite runs wherever a
  request is redacted and never on a response.
- One codec step turns an exchange into its stored form under a redaction.
  Encoding uses it, `cassette.redact` exposes it, and the recorder's streamed
  fragments are tested against it. `cassette.redact` serves both the check
  of old cassettes against a grown policy and their cleaning without a live
  run.
- A script can repeat: after its last exchange playback starts again at the
  first. A test that answers any request with a built failure then needs no
  script sized to outlast every retry.
- Additions to the public verdict types arrive as separate functions, never
  as new fields or variants, because consumers pin those types.
- Mapping volatile values back into replies, choosing a cassette per
  concurrent run, refusing to publish a transient failure, guarding who may
  record and driving re-records stay with the consumer.

## Rationale and alternatives

- Code under test can treat a playback refusal as an ordinary provider
  failure, so a stale or half-used cassette passed its test. Only the
  playback session sees every request and holds the cursor. A matcher that
  copies mismatches to a side channel never sees exhaustion and makes every
  consumer rebuild the same report.
- `verify` returns a `Result`: an empty verdict from a live client would read
  as "every request matched". Each mismatch carries the expected request in
  the same form as the actual one, so a person sees both sides without the
  script.
- A deny-list stores any header nobody listed. An allow-list over every header
  set was rejected: replays would lose `content-type` and live failures would
  lose `retry-after`, and field redaction would treat a body without
  `content-type` as opaque, which fails open. Letting a named credential
  survive was rejected: no allow-list may store a credential header.
  Intersecting repeated allow-list calls was rejected as inconsistent with
  every other redaction call, which adds.
- The existing body hook cannot tell a request from a response, so a
  consumer normalising request times through it would also rewrite recorded
  answers. Telling the hook which side it rewrites would change its type, a
  breaking change; a separate request-only rewrite is additive.
- A check returning only positions was rejected for `cassette.redact`: one
  pure function lets a consumer find the changed part by its own comparison
  and fix the file, and it shares the recorder's rule that a rewritten
  response body is stored as one chunk.
- One `dropped` count rather than one per kind: any refusal fails a test, and
  the kept requests already show which kinds occurred. Keeping only the first
  refusals without a count was rejected because a verdict would then hide how
  much it left out; keeping each distinct refusal once was rejected because
  it hides how often a request repeated. The field was added before the
  verdict's first release, so its one consumer moved with it.
- A transient failure is consumer policy. `abort` cannot remove a published
  file, so a consumer either watches outcomes while recording and aborts
  before `finish`, or records to a scratch path, checks it and moves it into
  place. A new `RecordError` variant would be breaking.
- Mapping ids back into replies needs domain knowledge of which reply tokens
  are ids. One consumer does it today; the library takes it on when a second
  consumer needs the same mapping.

## Consequences

- An allow-list hides changes in unlisted request headers from matching, and
  files recorded under it cannot match without it unless re-recorded, the
  dropped headers are ignored, or a matcher compares only the header names
  the expected request holds.
- `cassette.redact` and matching are exact only when redacting a stored form
  once more changes nothing, across field redaction, the body hook and the
  request-body rewrite together.
- Cleaning an old cassette does not withdraw a secret already published in
  it or in version-control history; the secret is rotated and any history
  rewrite is the consumer's.
- The cassette text layout and the release version are open rulings in the
  design's pending ledger.

## Evidence

- dash-crm (Dash's back office) records its agent tests' real exchanges with
  Google's Gemini API, through llm_wire (an LLM provider client) and Fabric
  (an agent runtime), both built on HTTP Gun. Its tests met each case: a test expecting a provider failure passed on a stale cassette;
  a run that stopped early passed with unused exchanges; and to keep a
  time-normalising body hook from storing a placeholder in a recorded answer,
  the consumer had to rewrite only bodies shaped like a provider request.
- `testing.verify` and its tests in `test/http_gun_cassette_test.gleam`.
