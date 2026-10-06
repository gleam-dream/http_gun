#!/usr/bin/env python3
"""Reject empty/skipped tests and malformed or incomplete native load evidence."""

import argparse
import json
from pathlib import Path
import re


def tests(output: str) -> int:
    clean = re.sub(r"\x1b\[[0-9;]*m", "", output)
    counts = re.findall(r"^\s*(\d+) passed, no failures\s*$", clean, flags=re.M)
    if len(counts) != 1 or int(counts[0]) == 0:
        raise ValueError("Missing, empty or ambiguous successful Gleeunit summary")
    return int(counts[0])


def load(output: str):
    rows = [json.loads(line) for line in output.splitlines()]
    expected = {
        (protocol, count)
        for protocol in ["h1-concurrent", "h2-concurrent"]
        for count in [1, 10, 100, 1000]
    }
    expected.update(
        {
            ("large-stream", 1),
            ("large-slow-reader", 1),
            ("h2-slow-stream-plus-batch", 1000),
        }
    )
    if (
        len(rows) != 11
        or {(row["scenario"], row["requests"]) for row in rows} != expected
    ):
        raise ValueError("Expected all eleven distinct native load workloads")
    for row in rows:
        if row["scenario"] == "h2-concurrent" and row["connections"] != 1:
            raise ValueError("H2 load did not share one connection")
        if row["scenario"] == "h1-concurrent" and not 1 <= row["connections"] <= 4:
            raise ValueError("H1 load exceeded its connection bound")
        if row["scenario"].startswith("large") and row["bytes"] != 33554432:
            raise ValueError("Large load did not transfer the expected bytes")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("kind", choices=["tests", "load"])
    parser.add_argument("evidence", type=Path)
    args = parser.parse_args()
    text = args.evidence.read_text()
    if args.kind == "tests":
        print(f"{tests(text)} package tests passed without failures or skips")
    else:
        load(text)
        print("All eleven native load scenarios passed")
