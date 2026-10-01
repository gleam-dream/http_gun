"""Positive public test, then synchronous-delivery mutation in a disposable copy."""
from pathlib import Path
import argparse
import shutil
import subprocess
import sys
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--root', required=True, type=Path)
parser.add_argument('--output', required=True, type=Path)
args = parser.parse_args()
root = args.root.resolve()
sys.path.insert(0, str(root / 'dev'))
from sinal_source import extract
args.output.mkdir(parents=True, exist_ok=True)
with tempfile.TemporaryDirectory(prefix='http-gun-observer-control-') as directory:
    work = Path(directory)
    package = work / 'http_gun'
    package.mkdir()
    for name in ['src', 'test', 'gleam.toml', 'manifest.toml']:
        source = root / name
        if source.is_dir():
            shutil.copytree(source, package / name)
        else:
            shutil.copy2(source, package / name)
    extract(work / 'sinal')
    (package / 'test/observation_isolation_probe.gleam').write_text('import http_gun_telemetry_test\npub fn main() { http_gun_telemetry_test.blocked_observer_drops_without_stalling_bounded_batch_test() }\n')
    for mutated in [False, True]:
        if mutated:
            target = package / 'src/http_gun/telemetry.gleam'
            text = target.read_text()
            anchor = 'forwarder.emit(\n          ctx.emitter.target,\n          ctx.emitter.event,'
            assert text.count(anchor) == 1
            target.write_text(text.replace(anchor, 'sinal.emit(\n          ctx.emitter.event,'))
        path = args.output / ('synchronous-mutation.log' if mutated else 'bounded-positive.log')
        with path.open('wb') as log:
            result = subprocess.run(['gleam', 'run', '-m', 'observation_isolation_probe'], cwd=package, stdout=log, stderr=subprocess.STDOUT, timeout=90)
        if mutated:
            output = path.read_text()
            assert result.returncode != 0 and 'blocked_observer_drops_without_stalling_bounded_batch_test' in output and 'Error(Nil)' in output, output
        else:
            assert result.returncode == 0, path.read_text()
        print(f'{path.name}: exit {result.returncode}, expected outcome', flush=True)
