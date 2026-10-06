#!/usr/bin/env python3
"""Opt-in current LLM Wire check. Build only isolated source copies, never siblings.

Run inside HTTP Gun's pinned dev environment. Relative local dependencies are
discovered from the selected manifests; HTTP Gun is explicitly overridden.
Receipts identify working-tree bytes, not just HEAD. No provider endpoints.
"""

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import signal
import subprocess
import tempfile
import tomllib
from sinal_source import verify


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
    selected = {}
    for name in sorted(set(names.decode().split("\0")) - {""}):
        if credential_name(name):
            continue
        path = root / name
        if name.startswith(
            (".archive/", "docs/history/evidence/", "build/", ".direnv/")
        ):
            continue
        if path.is_symlink() and not path.resolve().is_relative_to(root):
            raise ValueError(f"Source symlink leaves its checkout: {path}")
        if path.is_file():
            selected[name] = hashlib.sha256(path.read_bytes()).hexdigest()
    return {
        "revision": git(root, "rev-parse", "HEAD").decode().strip(),
        "status": git(root, "status", "--porcelain").decode(),
        "files": selected,
    }


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
        for relative in before[name]["files"]:
            source, target = root / relative, destination / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, target)
        for relative in before[name]["files"]:
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


def run(command, cwd, output, label, receipt, *, env=None):
    with (output / (label + ".log")).open("wb") as log:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            env=env,
        )
        try:
            code = process.wait(timeout=600)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            code = 124
    receipt["commands"].append(
        {"argv": command, "cwd": str(cwd), "exit": code, "log": label + ".log"}
    )
    print(f"{label}: exit {code}", flush=True)
    if code:
        raise RuntimeError(f"{label} failed; see {output / (label + '.log')}")


def local_http(downstream, output, receipt):
    selected = output / "local-http"
    run(
        ["python3", "dev/local-http.py"],
        downstream,
        output,
        "local-http",
        receipt,
        env=dict(os.environ, LLM_WIRE_HTTP_OUTPUT=str(selected)),
    )
    current = selected / "local-http.json"
    if not current.is_file() or not json.loads(current.read_text()):
        raise ValueError(
            "Downstream local HTTP runner did not retain a current receipt"
        )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--http-gun", required=True, type=Path)
    parser.add_argument("--llm-wire", required=True, type=Path)
    parser.add_argument(
        "--output",
        required=True,
        type=Path,
        help="New receipt directory outside all input checkouts",
    )
    args = parser.parse_args()
    roots = closure(args.http_gun.resolve(), args.llm_wire.resolve())
    verify(roots["sinal"])
    output = args.output.resolve()
    if any(output.is_relative_to(root) for root in roots.values()):
        parser.error("--output must be outside all input checkouts")
    output.mkdir(parents=True, exist_ok=False)
    before = {name: inputs(root) for name, root in roots.items()}
    receipt = {
        "sources": {
            name: {"path": str(roots[name]), **data} for name, data in before.items()
        },
        "host": platform.platform(),
        "commands": [],
        "passed": False,
    }
    try:
        with tempfile.TemporaryDirectory(prefix="http-gun-downstream-") as directory:
            copies = isolate(roots, before, Path(directory))
            downstream = copies["llm_wire"]
            for label, command in [
                ("gleam", ["gleam", "--version"]),
                (
                    "runtime",
                    [
                        "erl",
                        "-noshell",
                        "-eval",
                        'io:format("OTP ~s ERTS ~s~n", [erlang:system_info(otp_release), erlang:system_info(version)]), halt().',
                    ],
                ),
                ("nghttpd", ["nghttpd", "--version"]),
                ("check", ["gleam", "check"]),
                ("build", ["gleam", "build", "--warnings-as-errors"]),
                ("tests", ["gleam", "test"]),
                ("boundary", ["sh", "test/external_package_boundary.sh"]),
            ]:
                run(command, downstream, output, label, receipt)
            local_http(downstream, output, receipt)
            receipt["passed"] = True
    finally:
        receipt["originals_unchanged"] = all(
            inputs(root) == before[name] for name, root in roots.items()
        )
        receipt["passed"] &= receipt["originals_unchanged"]
        receipt["artifacts"] = {
            str(path.relative_to(output)): hashlib.sha256(path.read_bytes()).hexdigest()
            for path in sorted(output.rglob("*"))
            if path.is_file()
        }
        (output / "receipt.json").write_text(json.dumps(receipt, indent=2) + "\n")
        if not receipt["originals_unchanged"]:
            raise RuntimeError(
                "Input checkouts changed during the check; receipt is not accepted"
            )
    print(
        f"Current downstream passed; originals unchanged; receipt: {output / 'receipt.json'}"
    )


if __name__ == "__main__":
    main()
