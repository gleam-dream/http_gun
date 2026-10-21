#!/usr/bin/env python3
"""Opt-in current LLM Wire check. Build only isolated source copies, never siblings.

Run inside HTTP Gun's pinned dev environment. Relative local dependencies are
discovered from the selected manifests; HTTP Gun is explicitly overridden.
No provider endpoints or original checkout writes.
"""

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import tomllib

from isolated_process import run


def git(root, *args):
    return subprocess.check_output(["git", "-C", str(root), *args])


def credential_name(relative):
    for part in Path(relative).parts:
        name = part.lower()
        if (
            name == ".env"
            or name.startswith(".env.")
            or name.startswith(("credentials.", "secrets."))
            or name
            in {
                ".aws",
                ".ssh",
                ".gnupg",
                "credentials",
                "secrets",
                "id_rsa",
                "id_ed25519",
            }
        ):
            return True
    return False


def inputs(root):
    names = git(root, "ls-files", "--cached", "--others", "--exclude-standard", "-z")
    selected = []
    for name in sorted(set(names.decode().split("\0")) - {""}):
        if credential_name(name):
            continue
        path = root / name
        if name.startswith((".archive/", "docs/evidence/", "build/", ".direnv/")):
            continue
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise ValueError(f"Source symlink leaves its checkout: {path}")
        if path.is_file():
            selected.append(name)
    return selected


def closure(http_gun, llm_wire):
    roots = {"http_gun": http_gun, "llm_wire": llm_wire}
    pending = [http_gun, llm_wire]
    seen = set()
    while pending:
        root = pending.pop()
        if root in seen:
            continue
        seen.add(root)
        manifest = tomllib.loads((root / "gleam.toml").read_text())
        for section in ("dependencies", "dev-dependencies"):
            for name, value in manifest.get(section, {}).items():
                if not isinstance(value, dict) or "path" not in value:
                    continue
                target = (
                    http_gun if name == "http_gun" else (root / value["path"]).resolve()
                )
                actual_name = tomllib.loads((target / "gleam.toml").read_text())["name"]
                if actual_name != name or (name in roots and roots[name] != target):
                    raise ValueError(f"Conflicting local package: {name}")
                roots[name] = target
                pending.append(target)
    return roots


def isolate(roots, before, work):
    destinations = {name: work / name for name in roots}
    for name, root in roots.items():
        destination = destinations[name]
        for relative in before[name]:
            source, target = root / relative, destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        for relative in before[name]:
            if Path(relative).name not in ("gleam.toml", "manifest.toml"):
                continue
            source, target = root / relative, destination / relative

            def relocate(match):
                original = (source.parent / match[1]).resolve()
                # HTTP Gun paths in the downstream may name a different checkout.
                if original.name == "http_gun":
                    return "path = " + json.dumps(str(destinations["http_gun"]))
                for package, package_root in roots.items():
                    if original.is_relative_to(package_root):
                        moved = destinations[package] / original.relative_to(
                            package_root
                        )
                        return "path = " + json.dumps(str(moved))
                raise ValueError(f"Unresolved local dependency in {source}: {original}")

            target.write_text(
                re.sub(r'path = "([^"\n]+)"', relocate, target.read_text())
            )
    return destinations


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--http-gun", required=True, type=Path)
    parser.add_argument("--llm-wire", required=True, type=Path)
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="New HTTP observation directory outside all input checkouts",
    )
    args = parser.parse_args()
    roots = closure(args.http_gun.resolve(), args.llm_wire.resolve())
    output = args.output.resolve()
    if any(output.is_relative_to(root) for root in roots.values()):
        parser.error("--output must be outside all input checkouts")
    output.mkdir(parents=True, exist_ok=False)
    before = {name: inputs(root) for name, root in roots.items()}
    with tempfile.TemporaryDirectory(prefix="http-gun-downstream-") as directory:
        copies = isolate(roots, before, Path(directory))
        downstream = copies["llm_wire"]
        commands = [
            ["gleam", "build", "--warnings-as-errors"],
            ["gleam", "test"],
            ["sh", "test/external_package_boundary.sh"],
            ["python3", "dev/local-http.py"],
        ]
        for command in commands:
            code = run(
                command,
                cwd=downstream,
                env=dict(os.environ, LLM_WIRE_HTTP_OUTPUT=str(output / "local-http")),
                timeout=600,
            )
            if code:
                raise SystemExit(code)
    print("Current downstream behavior tests passed")


if __name__ == "__main__":
    main()
