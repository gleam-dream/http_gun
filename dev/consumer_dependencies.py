#!/usr/bin/env python3
"""Qualify separate consumers against the root's selected Gun/Cowlib versions."""

import argparse
from pathlib import Path
import re
import shutil
import tomllib

NATIVE = ("gun", "cowlib")


def versions(manifest: Path) -> dict[str, str]:
    parsed = tomllib.loads(manifest.read_text())
    return {package["name"]: package["version"] for package in parsed["packages"]}


def prepare(consumer: Path, root: Path):
    selected = versions(root / "manifest.toml")
    manifest = consumer / "gleam.toml"
    text = manifest.read_text()
    for name in NATIVE:
        constraint = f'{name} = "== {selected[name]}"'
        if re.search(rf"^{name} = .*$", text, flags=re.M):
            text = re.sub(rf"^{name} = .*$", constraint, text, flags=re.M)
        else:
            text = text.replace(
                "[dependencies]\n", f"[dependencies]\n{constraint}\n", 1
            )
    manifest.write_text(text)


def retain(consumer: Path, root: Path, label: str):
    selected = versions(root / "manifest.toml")
    resolved = versions(consumer / "manifest.toml")
    for name in NATIVE:
        if resolved.get(name) != selected[name]:
            raise ValueError(
                f"{label}: {name} selected {resolved.get(name)}, expected {selected[name]}"
            )
    evidence = root / "build/evidence/manifests"
    evidence.mkdir(parents=True, exist_ok=True)
    shutil.copy2(consumer / "manifest.toml", evidence / f"{label}.toml")
    print(
        f"{label}: qualified Gun {resolved['gun']}, Cowlib {resolved['cowlib']}, stdlib {resolved['gleam_stdlib']}"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "retain"])
    parser.add_argument("consumer", type=Path)
    parser.add_argument("label")
    args = parser.parse_args()
    if args.action == "prepare":
        prepare(args.consumer, Path.cwd())
    else:
        retain(args.consumer, Path.cwd(), args.label)
