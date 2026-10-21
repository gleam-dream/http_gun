#!/usr/bin/env python3
"""Assert connection sharing, bounds and transferred bytes in local load tests."""

import json
from pathlib import Path
import sys


def load(output: str):
    rows = [json.loads(line) for line in output.splitlines()]
    for row in rows:
        if row["scenario"] == "h2-concurrent" and row["connections"] != 1:
            raise ValueError("H2 load did not share one connection")
        if row["scenario"] == "h1-concurrent" and not 1 <= row["connections"] <= 4:
            raise ValueError("H1 load exceeded its connection bound")
        if row["scenario"].startswith("large") and row["bytes"] != 33554432:
            raise ValueError("Large load did not transfer the expected bytes")


if __name__ == "__main__":
    load(Path(sys.argv[1]).read_text())
    print("Native load behavior assertions passed")
