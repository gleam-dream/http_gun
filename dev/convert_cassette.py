#!/usr/bin/env python3
"""Convert an HTTP Gun cassette from schema 1 to schema 2, in place or to a new file.

Schema 2 stores each body and chunk as {"text": ..} when it is valid UTF-8 and
{"base64": ..} otherwise, names endings finished/aborted/abandoned, and stores
failures in the `error.to_json` shape. Exchanges, order, headers and bytes are
unchanged. Usage:

    python3 dev/convert_cassette.py OLD.json [NEW.json]
"""

import base64
import json
import sys

LIMITS = {
    "request_body_bytes": "request_body_bytes",
    "request_header_bytes": "request_header_bytes",
    "request_header_count": "request_header_count",
    "response_header_bytes": "response_header_bytes",
    "response_header_count": "response_header_count",
    "response_chunk_bytes": "buffered_bytes",
    "response_queue_bytes": "buffered_bytes",
    "collected_body_bytes": "response_body_bytes",
}
PLAIN = {
    "client_closed": "client_closed",
    "admission_full": "admission_full",
    "destination_rejected": "destination_rejected.host_not_allowed",
    "resolution_failed": "resolution_failed",
    "deadline": "deadline_exceeded",
    "read_timeout": "idle_timeout",
    "read_conflict": "read_conflict",
    "wrong_owner": "wrong_owner",
    "cancelled": "cancelled",
    "closed": "closed",
    "fixture_exhausted": "playback_exhausted",
    "capture_failed": "recording_closed",
}


def chunk(value):
    raw = base64.b64decode(value["base64"])
    assert len(raw) == value["bytes"], "byte count mismatch"
    try:
        return {"text": raw.decode("utf-8")}
    except UnicodeDecodeError:
        return {"base64": value["base64"]}


def failure(value):
    tag, detail = value["reason"], value["detail"]
    evidence = {"not_submitted": "not_sent", "may_have_been_sent": "maybe_sent"}[
        value["evidence"]
    ]
    out = {"evidence": evidence}
    if tag in PLAIN:
        out["name"] = PLAIN[tag]
    elif tag in ("connection_failed", "request_failed"):
        out["name"] = f"{tag}.{detail}"
    elif tag == "limit":
        out["name"] = "limit_exceeded." + LIMITS[detail]
        out["limit"] = value["count"]
        out["observed"] = value["observed"]
    elif tag == "fixture_mismatch":
        out["name"] = "playback_mismatch"
        out["position"] = value["count"]
    elif tag == "invalid_request":
        out["name"] = "invalid_request.invalid_target"
    else:
        raise SystemExit(f"failure reason {tag!r} has no schema 2 equivalent")
    return out


def ending(value):
    kind = value["kind"]
    if kind == "complete":
        return {"kind": "finished", "trailers": value["trailers"]}
    if kind == "failed":
        return {"kind": "aborted", "failure": failure(value["failure"])}
    if kind == "cancelled":
        return {"kind": "abandoned"}
    raise SystemExit(f"unknown ending {kind!r}")


def reply(value):
    if value["kind"] == "reject":
        return {"kind": "reject", "failure": failure(value["failure"])}
    return {
        "kind": "response",
        "status": value["status"],
        "headers": value["headers"],
        "chunks": [chunk(c) for c in value["chunks"]],
        "ending": ending(value["ending"]),
    }


def convert(document):
    if document.get("http_gun") == 2:
        return document
    assert document.get("http_gun") == 1, "not an HTTP Gun schema 1 cassette"
    exchanges = []
    for exchange in document["exchanges"]:
        request = exchange["request"]
        exchanges.append(
            {
                "request": {
                    "method": request["method"],
                    "url": request["url"],
                    "headers": request["headers"],
                    "body": chunk(request["body"]),
                },
                "reply": reply(exchange["reply"]),
            }
        )
    return {"http_gun": 2, "exchanges": exchanges}


if __name__ == "__main__":
    if len(sys.argv) not in (2, 3):
        raise SystemExit(__doc__)
    with open(sys.argv[1]) as source:
        converted = convert(json.load(source))
    with open(sys.argv[-1], "w") as target:
        json.dump(converted, target, indent=2, ensure_ascii=False)
        target.write("\n")
