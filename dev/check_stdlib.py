#!/usr/bin/env python3
"""Qualify the advertised lower bound and selected current stdlib in public copies."""

from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile

from consumer_dependencies import prepare, retain, versions
from sinal_source import extract

root = Path(__file__).resolve().parent.parent
config = (root / "gleam.toml").read_text()
lower = re.search(r'^gleam_stdlib = ">= ([0-9.]+) and < 2.0.0"$', config, re.M)
if lower is None:
    raise ValueError("Cannot determine the advertised stdlib lower bound")
selected = versions(root / "manifest.toml")["gleam_stdlib"]
for stdlib in dict.fromkeys([lower[1], selected]):
    with tempfile.TemporaryDirectory(prefix="http-gun-stdlib-") as directory:
        work = Path(directory)
        package = work / "http_gun"
        package.mkdir()
        for name in ["src", "test", "dev", "examples", "gleam.toml", "manifest.toml"]:
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
        extract(work / "sinal")
        consumer = work / "consumer"
        (consumer / "src").mkdir(parents=True)
        (consumer / "gleam.toml").write_text(f"""name = "stdlib_consumer"
version = "0.1.0"
target = "erlang"
[dependencies]
http_gun = {{ path = "../http_gun" }}
gleam_stdlib = "== {stdlib}"
""")
        (consumer / "src/stdlib_consumer.gleam").write_text("""import http_gun/config
pub fn main() {
  let assert Ok(_) = config.validate(config.default())
}
""")
        prepare(consumer, root)
        subprocess.run(
            ["gleam", "build", "--warnings-as-errors"], cwd=consumer, check=True
        )
        subprocess.run(["gleam", "run"], cwd=consumer, check=True)
        retain(consumer, root, f"stdlib-{stdlib}-consumer")
        manifest = package / "gleam.toml"
        manifest.write_text(
            re.sub(
                r"^gleam_stdlib = .*$",
                f'gleam_stdlib = "== {stdlib}"',
                manifest.read_text(),
                flags=re.M,
            )
        )
        subprocess.run(
            ["gleam", "update", "gleam_stdlib", "gleeunit"], cwd=package, check=True
        )
        try:
            subprocess.run(
                ["sh", "dev/gate", "fast"],
                cwd=package,
                env=dict(os.environ, HTTP_GUN_ISOLATED_GATE="1"),
                check=True,
            )
            retain(package, root, f"stdlib-{stdlib}-package")
        finally:
            evidence = package / "build/evidence"
            if evidence.exists():
                shutil.copytree(
                    evidence,
                    root / "build/evidence" / f"stdlib-{stdlib}",
                    dirs_exist_ok=True,
                )
        print(f"Public stdlib {stdlib} consumer and HTTP Gun fast gate passed.")
