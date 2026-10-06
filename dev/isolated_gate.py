#!/usr/bin/env python3
"""Run the package gate with pinned Sinal and retain selected consumer manifests."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

from consumer_dependencies import retain, versions
from isolated_process import run
from sinal_source import extract, verify

root = Path(__file__).resolve().parent.parent
selection = os.environ.get("HTTP_GUN_DEPENDENCIES", "minimum")
if selection not in ["minimum", "latest"]:
    raise ValueError(f"Unknown dependency selection: {selection}")
if (root.parent / "sinal").exists():
    verify(root.parent / "sinal")
with tempfile.TemporaryDirectory(prefix="http-gun-gate-") as directory:
    workspace = Path(directory)
    package = workspace / "http_gun"
    package.mkdir()
    for name in ["src", "test", "examples", "dev", "gleam.toml", "manifest.toml"]:
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
            shutil.copy2(source, package / name)
    extract(workspace / "sinal")
    evidence = package / "build/evidence"
    evidence.mkdir(parents=True)
    env = dict(os.environ, HTTP_GUN_ISOLATED_GATE="1")
    started = time.monotonic()
    summary = {
        "profile": sys.argv[1] if len(sys.argv) > 1 else "fast",
        "dependency_selection": selection,
        "result": "failure",
    }
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
        summary["resolved_versions"] = versions(package / "manifest.toml")
        summary["result"] = "success" if code == 0 else "failure"
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        summary["error"] = str(error)
        print(f"Isolated gate failed: {error}", flush=True)
        code = 1
    finally:
        summary["exit_code"] = code
        summary["elapsed_seconds"] = round(time.monotonic() - started, 3)
        (evidence / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        shutil.copytree(evidence, root / "build/evidence", dirs_exist_ok=True)
    raise SystemExit(code)
