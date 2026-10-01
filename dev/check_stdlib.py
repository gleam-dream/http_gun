#!/usr/bin/env python3
"""Resolve a public consumer with stdlib 1.x, then test HTTP Gun on that pin."""
from pathlib import Path
import os
import re
import shutil
import subprocess
import tempfile
from sinal_source import extract

root = Path(__file__).resolve().parent.parent
with tempfile.TemporaryDirectory(prefix="http-gun-stdlib-") as directory:
    work = Path(directory)
    package = work / "http_gun"
    package.mkdir()
    for name in ["src", "test", "dev", "examples", "gleam.toml", "manifest.toml"]:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, package / name)
        else:
            shutil.copy2(source, package / name)
    extract(work / "sinal")
    consumer = work / "consumer"
    (consumer / "src").mkdir(parents=True)
    (consumer / "gleam.toml").write_text('''name = "stdlib_consumer"
version = "0.1.0"
target = "erlang"
[dependencies]
http_gun = { path = "../http_gun" }
gleam_stdlib = "== 1.0.5"
''')
    (consumer / "src/stdlib_consumer.gleam").write_text('''import http_gun/config
pub fn main() {
  let assert Ok(_) = config.validate(config.default())
}
''')
    subprocess.run(["gleam", "run"], cwd=consumer, check=True)
    # After proving the real public bounds resolve together, pin the tested
    # stdlib in this disposable package to qualify its full fast gate too.
    manifest = package / "gleam.toml"
    manifest.write_text(re.sub(r'^gleam_stdlib = .*$',
                              'gleam_stdlib = "== 1.0.5"',
                              manifest.read_text(), flags=re.M))
    (package / "manifest.toml").unlink()
    subprocess.run(["sh", "dev/gate", "fast"], cwd=package,
                   env=dict(os.environ, HTTP_GUN_ISOLATED_GATE="1"), check=True)
    print("Public stdlib 1.0.5 consumer and HTTP Gun fast gate passed.")
