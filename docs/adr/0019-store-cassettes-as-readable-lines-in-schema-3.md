<a id="adr-0019"></a>

# 0019: Store cassettes as readable lines in schema 3

Date: 2026-11-18
Status: Accepted

## Decision

- Cassettes carry marker `http_gun: 3`, the only marker HTTP Gun writes.
  While consumers convert, it also reads marker 2; that reader is retired as
  below. This supersedes ADR 0005's "one current schema" for that period;
  there is still no fallback to a live request.
- A UTF-8 body or chunk that contains a newline is stored as `lines`, the
  strings between its newlines, and rebuilt by joining them with a newline.
  Other UTF-8 bytes stay `text`; bytes that are not UTF-8 stay `base64`.
  Schema 2 has no `lines` kind.
- The codec owns one text layout and every fragment of it, separators and
  closing brackets included:
  laid out over many lines, indented by nesting, each header pair, chunk and body
  line on a line of its own, and a final newline; body, chunk, ending
  and reject objects open on their field's line, and a stored failure stays
  on one line. Separators lead elements and a closing bracket depends only on
  whether the array held an element, so the recorder streams fragments with
  no lookahead. The recorder writes only codec fragments, and the budget is
  charged on every byte the file holds.
- Schema 3 stores a request's scheme, host, port, path and query as separate
  fields, read back without URL parsing; schema 2 keeps its single URL.
- `cassette.encode` lays a script out and applies no redaction, so
  converting is parsing then encoding: no recorded answer changes, and it
  needs no credentials and no live request. Keeping credentials out of a
  file is the job of recording and of `cassette.redact`.
- The schema 2 reader is retired in the same release, once the cassettes of
  LLM Wire and Fabric, the known schema 2 readers, are converted.
- This settles the cassette text layout left as an open ruling by ADR 0018.

## Rationale and alternatives

- A cassette of an LLM conversation is mostly body. On one line, a
  re-record shows as one changed line for the whole file. Lines make an
  indented answer or a streamed reply diff line by line.
- `lines` is exact by construction: splitting at every newline and joining
  with a newline is the identity on any string, so carriage returns, a final
  newline and empty lines come back as they were. No answer can be altered,
  as the owner requires of every recorded answer.
- Storing JSON bodies as parsed JSON was rejected: parsing and writing back
  loses key order, number spelling, string escapes, duplicate keys and
  whitespace, so replay would not return the provider's bytes, and streamed
  replies are not JSON at all.
- Storing a JSON body verbatim as a JSON value, recovered by scanning its span
  in the file, and storing a compact body indented, recovered by removing
  whitespace outside strings, would also make compact request bodies
  and compact response bodies readable. Both need
  a span scanner over the cassette text, a strict validity check and an exact
  whitespace remover, and a bug in any of them returns different bytes, the
  failure the owner forbids. They are kept as a possible later addition.
  An older decoder takes the first kind it knows and reports Corrupt when it
  finds none, so a new kind would be misread or reported as corrupt rather
  than as an unsupported version; such an addition would be schema 4, read
  alongside 2 and 3.
  The verbatim and indented kinds are worth reconsidering only if a
  re-record shows a prompt change or a changed answer as one changed body
  line; a cheaper path for requests is then for the model library to send
  indented request JSON, which lines already stores exactly.
- `cassette.encode` used to apply the default redaction, which rewrote
  fields in a file recorded before field redaction existed and turned a
  truncated JSON body into `REDACTED-UNPARSABLE`, altering a recorded answer.
  A separate conversion function that skipped the redaction was tried and
  dropped: it left four overlapping paths (recording, `redact`, `encode`'s
  implicit default and the conversion's bypass) where two suffice. Keeping
  only the credential headers in `encode` was also weighed; the owner chose
  layout only, moving the 0.1.0 promise that `encode` never writes a
  credential header to recording and `redact`.
- Keeping the schema 2 reader indefinitely was rejected: the known readers
  are the owner's own packages, and converting them is cheap.
- A stored failure stays one line: its fields come from `error.to_json`, and
  laying them out field by field would need a second serializer kept in step
  with it. OTP's `json:format` was not used: its output is not specified to
  stay the same across OTP releases, and it cannot write streamed fragments.
- Compact storage with a renderer for review was rejected because hosted diff
  views ignore diff drivers; one line per exchange still leaves every body on
  one line.
- A single URL was rejected for schema 3: reading it back through a URL
  parser loses targets that live requests accept. A query with brackets,
  braces, a pipe or quotes, a non-ASCII path or a control character makes
  the file fail to load; an IPv6 host or a `?` or `#` in a path loads as a
  different request. Refusing those targets on live requests would change
  what clients accept; refusing them only when recording would fail
  recordings late. Separate fields need no parsing and read back exactly.
- Writing fragments from the codec, instead of reformatting the assembled
  file at publication, keeps the recorder's streaming writes and its bounded
  memory (ADR 0005), and leaves one copy of the layout.

## Consequences

- An older HTTP Gun reading a schema 3 file fails with `UnsupportedVersion`.
- A schema 2 file holding a target its URL cannot carry stays as it was: it
  either failed to load already and cannot be converted, or it loads as the
  different request it always replayed as and converts as that request. A
  file that loads but holds a target a client could not send, such as port
  0, encodes to text `parse` refuses.
- A hand-built script keeps, when encoded, the credentials its responses
  hold: credential response or trailer headers, failure headers and
  credential fields in response bodies (`testing.exchange` already redacts
  the request). A caller who wants them out applies `cassette.redact` first.
- After the schema 2 reader is retired, an unconverted schema 2 file fails
  with `UnsupportedVersion(2)`.
- `cassette.encode` output changes for anyone comparing it to a stored string.
- Files grow by their indentation and line structure, against the recording
  budget, whose 16 MiB ceiling is unchanged, and a caller's `load` limit. A
  streamed reply grows most, since every chunk carries its own lines. The
  measured growth of a streamed and a buffered cassette is recorded under
  Evidence when built.
- A compact request or response body stays one line: lines help only bodies
  with a raw newline, such as indented JSON and streamed replies.
- Chunk boundaries are part of a recorded answer, so two recordings of the
  same streamed answer with different chunking differ at every boundary, and
  an event split across chunks shows as broken lines.

## Evidence

- The owner chose lines after the comparison of JSON storage, verbatim
  storage and lines for byte fidelity, then chose `cassette.encode` as layout
  only and the retirement of the schema 2 reader after converting LLM Wire
  and Fabric, in the planning of pull requests gleam-dream/http_gun#8 and
  gleam-dream/http_gun#9.
- llm_wire encodes request bodies with `json.to_string`, compact on one line.
- Whether dash-crm's recorded answers are streamed or buffered, and indented
  or compact, is not yet measured; its first real recordings settle it.
- Growth measured on synthetic Gemini-shaped exchanges with a 1.6 KB prompt:
  a 200-event SSE answer went from 49,518 bytes in schema 2 to 63,116 in
  schema 3 (27 % more), and an indented 1.2 KB JSON answer from 3,494 to
  3,969 bytes (14 % more).
