#!/usr/bin/env python3
"""Independently compile HTTP Gun's authored Erlang with warning rejection."""

import argparse
from pathlib import Path
import subprocess
import tempfile


def command(root: Path, output: Path) -> list[str]:
    sources = sorted(root.glob("src/**/*.erl")) + sorted(root.glob("test/**/*.erl"))
    if not sources:
        raise ValueError("No authored Erlang modules found")
    args = ["erlc", "-Werror", "-o", str(output)]
    for pattern, option in [
        ("build/packages/*/include", "-I"),
        ("build/dev/erlang/*/include", "-I"),
        ("build/dev/erlang/*/ebin", "-pa"),
    ]:
        for directory in sorted(root.glob(pattern)):
            args.extend([option, str(directory)])
    return args + [str(source) for source in sources]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, default=Path.cwd())
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="http-gun-native-") as directory:
        compiled = command(args.source.resolve(), Path(directory))
        print(" ".join(compiled), flush=True)
        subprocess.run(compiled, check=True)
