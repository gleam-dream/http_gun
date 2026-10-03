#!/usr/bin/env python3
"""Run the normal package gate with its pinned Sinal source, without siblings."""
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from sinal_source import extract, verify

root = Path(__file__).resolve().parent.parent
if (root.parent / "sinal").exists():
    verify(root.parent / "sinal")
with tempfile.TemporaryDirectory(prefix='http-gun-gate-') as directory:
    workspace = Path(directory)
    package = workspace / 'http_gun'
    package.mkdir()
    for name in ['src', 'test', 'examples', 'dev', 'gleam.toml', 'manifest.toml']:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, package / name)
        else:
            shutil.copy2(source, package / name)
    extract(workspace / 'sinal')
    env = dict(os.environ, HTTP_GUN_ISOLATED_GATE='1')
    # CI's "latest" job takes the newest gun and cowlib patch inside the
    # declared ranges; the default job keeps the committed minimum.
    if os.environ.get('HTTP_GUN_DEPENDENCIES') == 'latest':
        subprocess.run(['gleam', 'update', 'gun', 'cowlib'], cwd=package, env=env, check=True)
        subprocess.run(['gleam', 'deps', 'list'], cwd=package, env=env, check=True)
    code = subprocess.run(['sh', 'dev/gate', *sys.argv[1:]], cwd=package, env=env).returncode
    evidence = package / 'build/evidence'
    if evidence.exists():
        shutil.copytree(evidence, root / 'build/evidence', dirs_exist_ok=True)
    raise SystemExit(code)
