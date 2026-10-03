"""Validate the selected canonical Sinal source using only disposable build trees."""
import argparse
from pathlib import Path
import shutil
import subprocess
import tempfile
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--source', type=Path, required=True)
args = parser.parse_args()
with tempfile.TemporaryDirectory(prefix='sinal-final-gate-') as directory:
    root = Path(directory)
    for name in ['src', 'test', 'dev', 'gleam.toml', 'manifest.toml', 'README.md']:
        source = args.source / name
        if source.is_dir():
            shutil.copytree(source, root / name)
        else:
            shutil.copy2(source, root / name)
    def run(command):
        print('+', ' '.join(command), flush=True)
        subprocess.run(command, cwd=root, check=True, timeout=90)
    run(['gleam', '--version'])
    run(['erl', '-noshell', '-eval', 'io:format("OTP ~s ERTS ~s~n",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'])
    run(['gleam', 'format', '--check', 'src', 'test'])
    run(['gleam', 'check'])
    run(['gleam', 'build', '--warnings-as-errors'])
    run(['gleam', 'test'])
    out = root / 'ffi-check'
    out.mkdir()
    run(['erlc', '-Werror', '-o', str(out), *[str(p) for folder in ['src', 'test'] for p in (root / folder).glob('*.erl')]])
    run(['python3', 'dev/check_forwarder.py'])
    print('FINAL SINAL GATE PASSED', flush=True)
