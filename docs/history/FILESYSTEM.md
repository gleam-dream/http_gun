# Filesystem reuse and retained guarantees

The owner approved keeping Gun and reusing released filesystem libraries where they preserve HTTP Gun's guarantees. This is an internal implementation change; the cassette API and fixture format stay unchanged. No dependency is patched or copied into production source.

## Selected libraries

| Library | Decision | Verified source behavior used |
| --- | --- | --- |
| file_streams 1.7.0 | Adopt, `>= 1.7.0 and < 2.0.0` | Explicit Raw/Read and bounded read_bytes; Raw/Write/Exclusive and Raw/Append; binary IO and Result-returning close |
| simplifile 2.7.0 | Adopt, `>= 2.7.0 and < 3.0.0` | Directory creation, permissions, hard links, rename and file-only removal delegate to OTP filesystem operations |
| file_streams 2.0.0 | Defer | Requires stdlib1; 1.7.0 supports the selected stdlib0.71 without an unrelated runtime-library migration |
| fio 1.2.1 | Do not adopt for this wave | Requires stdlib1; selected libraries cover the required operations without changing the existing dependency matrix |

Both libraries are used only through their public APIs, so `gleam.toml` admits their current major versions; manifest.toml locks the resolved releases and transitive filepath with checksums. [Review hashes](filesystem-review.json) identify the published archives and source inventories, including package license files. No donor source was reused. References: [file_streams](https://hex.pm/packages/file_streams/1.7.0), [simplifile](https://hex.pm/packages/simplifile/2.7.0), [fio](https://hex.pm/packages/fio/1.2.1).

## Guarantees at the integration boundary

- Bounded reads request at most the limit plus one byte, using explicit modes without read-ahead. The extra byte distinguishes an exactly full fixture from an oversized one. Empty files remain corrupt fixtures, and missing files remain explicit errors.
- Spool files use the library's Exclusive mode, which maps to OTP exclusive open on the Erlang target. simplifile.create_file checks before writing, so it is not used for this contract. Guarantees assume a local filesystem that supports exclusive creation and atomic links/renames.
- Writes use explicit modes without delayed-write buffers. Gleam always closes normally opened handles, propagates normal close failures, and preserves the primary operation failure when both fail. A small exception helper closes on an unexpected exception before re-raising it. Capture acknowledgements follow the completed write/close, not an extra library write buffer; this is not fsync durability.
- Recording creates an exclusive temporary directory beside the destination and sets mode0700 before storing request data. A unique candidate path does not itself establish exclusivity; successful directory creation does. A collision fails rather than reusing an existing directory.
- RefuseExisting publishes through a hard link; ReplaceExisting uses rename. There is no check-then-overwrite fallback. IO and destination-exists failures keep their existing typed outcomes.
- Cleanup removes known files and then an empty directory. simplifile.delete is recursive, so a small empty-directory removal bridge is retained. Interrupted or failed recordings may leave temporary data as before.

The remaining filesystem Erlang module only constructs a unique candidate name and removes an empty directory. No handwritten Erlang file reader, writer, recorder or publication policy remains. Pool, body and recording actors continue to be Gleam code.

## Optional features owned by HTTP Gun

Body/query redaction would add explicit query filtering and bounded whole-body transformation or exclusion, together with compatible request matching. It must not pretend that independent chunk replacement handles secrets split across chunks. Current recordings retain exact bodies and queries, which can contain secrets.

Durable publication would add file and directory synchronization with an explicit supported-platform contract. Atomic publication currently guarantees visibility of a complete fixture; it does not guarantee persistence through power loss. file_streams exposes file synchronization, but that alone does not define the full publication durability contract. These are optional client features, independent of Gun/Cowlib.
