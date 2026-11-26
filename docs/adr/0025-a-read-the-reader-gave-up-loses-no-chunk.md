<a id="adr-0025"></a>

# 0025: A read the reader gave up loses no chunk

Date: 2026-11-26
Status: Accepted

## Decision

- The reading process enforces the local wait of `body.next_within` as well
  as the request deadline: it waits for the body owner until the earlier of
  the two plus the grace of ADR 0021. When the local wait ends first and the
  owner has not answered, the read returns `None`, as when the owner itself
  ends the wait.
- Each read carries the number of chunks the reader has received, counted in
  a counter that every copy of the body shares. The body owner keeps the last
  chunk it sent until a later read shows that the reader received it. A read
  whose count shows the chunk never arrived receives that chunk again.
- A read from the owning process replaces a read wait the owner still holds:
  the reading process waits for one read at a time, so it has given the
  earlier one up. A read from any other process still meets `ReadConflict`
  while a read waits, and `WrongOwner` otherwise.

## Rationale and alternatives

- ADR 0021 bounded every reply by the request deadline, so a body owner that
  could not answer held `next_within(10 ms)` until the request deadline plus
  the grace. The local wait is the caller's own bound and must hold even when
  the owner is stalled.
- Once the reader stops waiting, its reply subject drops every later message.
  A body owner that resumed afterwards removed a chunk from its cursor and
  sent it to that subject, so the next read skipped it. An acknowledgement
  message per chunk would add a round trip to every read. The count travels
  with the next read instead, which the reader sends anyway, and the owner
  holds at most one chunk more than before.
- Refusing the replacing read with `ReadConflict` left the reader unable to
  read again until the abandoned wait ended inside the owner.

## Evidence

- `test/http_gun_caller_deadline_test.gleam`
  (`local_wait_ends_on_a_blocked_owner_and_keeps_its_chunk_test`) suspends the
  body owner with one chunk in its mailbox and reads with a 100 ms local wait.
  Before the change the read was still waiting after two seconds. With the
  caller-side bound alone and no redelivery, the next read after the owner
  resumed never received the chunk.
