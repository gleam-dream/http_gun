#!/usr/bin/env python3
"""Run the package gate in an isolated workspace and retain selected consumer manifests."""

import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

from consumer_dependencies import retain
from isolated_process import run

root = Path(__file__).resolve().parent.parent
selection = os.environ.get("HTTP_GUN_DEPENDENCIES", "minimum")
if selection not in ["minimum", "latest"]:
    raise ValueError(f"Unknown dependency selection: {selection}")
with tempfile.TemporaryDirectory(prefix="http-gun-gate-") as directory:
    workspace = Path(directory)
    package = workspace / "http_gun"
    package.mkdir()
    for name in [
        "src",
        "test",
        "examples",
        "dev",
        "gleam.toml",
        "manifest.toml",
        "flake.nix",
        "flake.lock",
        "docs/evidence/dream-comparison/source.json",
    ]:
        source = root / name
        if source.is_dir():
            shutil.copytree(
                source,
                package / name,
                ignore=shutil.ignore_patterns(
                    "build", "__pycache__", "results", ".env*"
                ),
            )
        else:
            (package / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, package / name)
    evidence = package / "build/evidence"
    evidence.mkdir(parents=True)
    env = dict(os.environ, HTTP_GUN_ISOLATED_GATE="1")
    code = 1
    try:
        if selection == "latest":
            with (evidence / "dependency-update.log").open("w") as log:
                subprocess.run(
                    ["gleam", "update", "gun", "cowlib"],
                    cwd=package,
                    env=env,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    check=True,
                )
        code = run(
            ["sh", "dev/gate", *sys.argv[1:]],
            cwd=package,
            env=env,
            timeout=1800,
        )
        retain(package, package, "root")
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        print(f"Isolated gate failed: {error}", flush=True)
        code = 1
    finally:
        shutil.copytree(evidence, root / "build/evidence", dirs_exist_ok=True)
    raise SystemExit(code)
