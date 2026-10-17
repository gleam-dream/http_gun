# Compose independent cancellation authorities

<a id="adr-0012"></a>

## Decision

- On 2026-10-16 the approved Relay request-budget implementation required local cancellation during subscription opening while preserving the application's cancellation on its borrowed client. The local opening owner can disarm its bound after stream handoff without cancelling application work.
- An additive client-view operation retains each distinct token. Existing with_cancellation keeps its replacement semantics; neither operation changes token ownership or creates a process.
- Pending requests and body owners monitor every retained token. Terminal paths release all monitors without cancelling any source token.

## Alternatives and limits

- Replacing the borrowed token removes application cancellation from the operation. A forwarding token process adds another lifecycle and cannot be represented by a pure client view.
- Cancellation remains local and retains submission evidence. The application bounds the number and lifetime of token scopes; adding a token does not provide provider rollback or a hard callback-return deadline.
