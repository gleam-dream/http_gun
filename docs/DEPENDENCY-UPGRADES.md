# Dependency qualification

## Gun and Cowlib

- Current ranges are Gun `>= 2.6.0 and < 2.7.0` and Cowlib `>= 2.20.0 and < 2.21.0`. The committed manifest resolves the minimum. The [range decision](adr/0007-patch-ranges-require-native-contract-audits.md) owns rationale.
- Before widening a minor range, inspect the candidate source for each assumption below. Preserve failure evidence and update typed conversion only under an accepted contract.

| Assumption                                                                       | Source                                                    | If changed                                                                                     |
| -------------------------------------------------------------------------------- | --------------------------------------------------------- | ---------------------------------------------------------------------------------------------- |
| `gun:info/1` returns `state_name: connected` and protocol `http` for reusable H1 | `src/http_gun_ffi.erl:reusable/1`                         | Missing/unknown state refuses reuse; confirm replacement stays before submission               |
| Structured `gun_error`/`gun_down` reasons                                        | `cause/1`, `decode/1`                                     | UnknownTransport loses detail; never infer NotSent from an unknown reason                      |
| Gun calls its event handler with the terminal reason before process exit         | `src/http_gun_event_h.erl:terminate/2`, Gun `terminate/3` | Retain the original owner and typed reason when the owner installs its monitor after Gun exits |
| Request call returns asynchronously before socket processing                     | `request/5`, reviewed Gun request implementation          | MaybeSent begins at invocation; no hidden retry                                                |
| H2 header count includes `:status`                                               | `open/9` and Gun/Cowlib source                            | Keep ordinary-header admission exact after parsing                                             |
| Settings-change notification and peer stream capacity                            | `decode/1`, `internal/pool.gleam`                         | No H2 streams before initial SETTINGS; reduction blocks new admission                          |
| Test-only `cow_http2` and `cow_hpack` operations                                 | `test/http_gun_h2_server.erl`                             | Requalify the test server before claiming H2 behavior                                          |

- Run the package's full gate on the committed minimum and newest admitted patches through the isolated environment. CI uses `HTTP_GUN_DEPENDENCIES=latest` for patch selection. The selected root Gun/Cowlib versions are imposed on disposable ordinary/async and stdlib consumer copies. The gate fails if a resolved consumer differs, and retains their manifests under `build/evidence/manifests`; keep native-source audit evidence reviewable.
- Requalify ordinary/async public consumers and explicitly selected downstream checkouts when public contracts change. Follow [TESTING.md](TESTING.md). Avoid provider credentials and dependency patches.

## Runtime and filesystem libraries

- Use the pinned Nix shell and runtime matrix. Gleam OTP/Erlang process APIs own native lifetime; public stdlib boundary checks compile a separate consumer and run the complete fast suite at the advertised lower bound (0.71.0) and selected current version. The disposable lower-bound package resolves a compatible Gleeunit within the existing dev-dependency range (0.71.0 selects Gleeunit 1.9.0); its test manifest is retained. Authored Erlang warning rejection remains separate from upstream diagnostics; stdlib 0.71.0 can emit OTP 29 deprecation diagnostics while the package-owned source still passes `erlc -Werror`.
- file_streams must preserve explicit Raw reads without read-ahead, Exclusive writes and close error reporting. simplifile must preserve hard-link/rename publication and permission semantics. Do not substitute a check-before-create helper for exclusivity.
- Any new durability promise requires a separate supported-platform contract. File sync alone is insufficient evidence of directory-entry persistence.
