# Isolated streaming consumer

Run through `./dev/env sh dev/consumers` from HTTP Gun's root. The gate builds this package against the hash-verified local LLM Wire archive, using public package imports. It never writes sibling checkouts or calls providers.

`stream` prepares a provider request, uses HTTP Gun's scoped byte stream, frames bounded SSE events and delivers public LLM Wire progress values synchronously. Returning `Stop` from the progress callback cancels locally; a provider terminal returns before HTTP EOF. `text` uses that same streaming path. Live, scripts, recording and playback use the same consumer functions.

The executable checks cover live progress, early stop, terminal-before-EOF, partial disconnect evidence, idle expiry, status/Retry-After, compression refusal, finite body/line admission, actual recording/playback and all 1196 byte split points across OpenAI/Anthropic/Google text fixtures, including UTF-8 and CRLF.

This is a text-oriented composition example, not a replacement for LLM Wire's session runtime. It does not implement tool execution, continuation, structured-output admission or all of that runtime's terminal/retry evidence. Transport failures and explicit cancellation retain observed-byte and reducer progress evidence; other example error variants do not expose the complete session evidence model. The application owns those policies. A production adapter must carry the remaining overall budget into its HTTP client policy and preserve the existing session semantics.

The client owns the overall request deadline, including admission and connection setup. Configure it appropriately at startup. The example treats the configured LLM idle wait as terminal by returning from the scope; a raw `body.next` timeout itself does not cancel. There is no per-request deadline override or pre-header cancellation handle in HTTP Gun. Ending the request's owning worker cancels opening work.

The bounded framer is retained from reviewed LLM Wire source, under the included [Apache license](LICENSE.llm_wire). Exact source revision and pre-reuse hashes are in [donor-source.json](../../docs/evidence/wave11/donor-source.json). It stays in this example; HTTP Gun's production dependency graph and API contain no SSE/provider layer. This retention is not a general SSE conformance claim.
