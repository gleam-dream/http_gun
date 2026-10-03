"""Pinned, local-only public API comparison. Run inside dev/env's Nix shell."""
from pathlib import Path
import argparse, collections, hashlib, json, os, platform, shutil, socket, statistics, subprocess, tarfile, urllib.request

ROOT = Path(__file__).resolve().parents[2]
WORK = ROOT / 'build/dream-comparison'
OUT = ROOT / 'docs/history/evidence/dream-comparison'
SHA = 'bbc4b5402a7e0cb5247829c8f4be8fb273afc2a5'
ARCHIVE_SHA = 'd518ec13f566dd8d60482eef0076fa562625fed4f1f2ffcbb38c4cbc1d8735fd'
DREAM = WORK / f'dream-{SHA}'
MODULE = DREAM / 'modules/http_client'
RUNNER = WORK / 'runner'


def record_inputs():
    files = [ROOT / file for file in ('gleam.toml', 'manifest.toml', 'flake.nix', 'flake.lock')]
    for directory in ('src', 'examples/comparison', 'dev/comparison'):
        files += [file for file in (ROOT / directory).rglob('*') if file.is_file() and '__pycache__' not in file.parts]
    files += list((ROOT / 'test').glob('*.erl')) + list((ROOT / 'test/fixtures').glob('*'))
    receipt = {
        'platform': platform.platform(), 'machine': platform.machine(), 'logical_cpus': os.cpu_count(),
        'gleam': subprocess.check_output(['gleam', '--version'], text=True).strip(),
        'erlang': subprocess.check_output(['erl', '-noshell', '-eval',
            'io:format("OTP ~s ERTS ~s schedulers ~p", [erlang:system_info(otp_release),erlang:system_info(version),erlang:system_info(schedulers_online)]),halt().'], text=True).strip(),
        'inputs': {str(file.relative_to(ROOT)): hashlib.sha256(file.read_bytes()).hexdigest() for file in sorted(files) if file.is_file()},
    }
    if platform.system() == 'Darwin':
        receipt['cpu'] = subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip()
        receipt['physical_memory_bytes'] = int(subprocess.check_output(['sysctl', '-n', 'hw.memsize'], text=True))
    (OUT / 'inputs.json').write_text(json.dumps(receipt, indent=2) + '\n')


def run(args, cwd, stem, timeout=180):
    with (OUT / f'{stem}.log').open('w') as log:
        try:
            completed = subprocess.run(args, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, timeout=timeout)
            code = completed.returncode
        except subprocess.TimeoutExpired:
            code = 'timeout'
    print(f'{stem}: {code}', flush=True)
    return code


def prepare():
    WORK.mkdir(parents=True, exist_ok=True)
    OUT.mkdir(parents=True, exist_ok=True)
    archive = WORK / f'dream-{SHA}.tar.gz'
    if not archive.exists():
        archive.write_bytes(urllib.request.urlopen(f'https://codeload.github.com/lostbean/dream/tar.gz/{SHA}').read())
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == ARCHIVE_SHA
    if not DREAM.exists():
        with tarfile.open(archive) as source:
            source.extractall(WORK, filter='data')
    receipt = json.loads((ROOT / 'docs/history/evidence/dream-comparison/source.json').read_text())
    for name, expected in receipt['module_files'].items():
        if not name.endswith('/manifest.toml'):
            assert hashlib.sha256((DREAM / name).read_bytes()).hexdigest() == expected, name
    ours = WORK / 'http_gun'
    ours.mkdir(exist_ok=True)
    shutil.copytree(ROOT / 'src', ours / 'src', dirs_exist_ok=True)
    for file in ('gleam.toml', 'manifest.toml'):
        shutil.copyfile(ROOT / file, ours / file)
    shutil.copytree(ROOT / 'examples/comparison/src', RUNNER / 'src', dirs_exist_ok=True)
    for file in ('gleam.toml', 'manifest.toml'):
        shutil.copyfile(ROOT / 'examples/comparison' / file, RUNNER / file)
    for file in ('http_gun_test_server.erl', 'http_gun_measure_ffi.erl', 'http_gun_h2_server.erl', 'http_gun_tls_test_server.erl'):
        shutil.copyfile(ROOT / 'test' / file, RUNNER / 'src' / file)
    shutil.copytree(ROOT / 'test/fixtures', RUNNER / 'test/fixtures', dirs_exist_ok=True)
    record_inputs()
    assert run(['gleam', 'build', '--warnings-as-errors'], RUNNER, 'harness-build') == 0


def upstream():
    # Never invoke Dream's Makefile: it kills unrelated port owners.
    with socket.socket() as probe:
        probe.bind(('127.0.0.1', 9876))
    with tarfile.open(WORK / f'dream-{SHA}.tar.gz') as archive:
        original = archive.extractfile(f'dream-{SHA}/modules/http_client/manifest.toml').read().decode()
    (MODULE / 'manifest.toml').write_text(original)
    raw = {name: run(args, MODULE, name, 360) for name, args in [
        ('dream-format', ['gleam', 'format', '--check']),
        ('dream-check', ['gleam', 'check']), ('dream-test', ['gleam', 'test'])]}
    (OUT / 'dream-suite.json').write_text(json.dumps(raw, indent=2) + '\n')
    reconciled = original.replace('name = "dream", version = "2.3.1"', 'name = "dream", version = "2.4.1"').replace('name = "dream_mock_server", version = "1.0.0"', 'name = "dream_mock_server", version = "1.1.1"')
    (MODULE / 'manifest.toml').write_text(reconciled)
    (OUT / 'dream-reconciled-manifest.toml').write_text(reconciled)
    results = {name: run(args, MODULE, name, 360) for name, args in [
        ('dream-reconciled-check', ['gleam', 'check']), ('dream-reconciled-test', ['gleam', 'test'])]}
    (OUT / 'dream-reconciled-suite.json').write_text(json.dumps(results, indent=2) + '\n')
    return all(code == 0 for code in results.values())


def contracts():
    for name in ('gun', 'dream'):
        result = subprocess.run(['gleam', 'run', '-m', 'comparison_contract', '--', name], cwd=RUNNER, capture_output=True, text=True, timeout=100)
        (OUT / f'{name}-contracts.jsonl').write_text(result.stdout)
        (OUT / f'{name}-contracts.stderr').write_text(result.stderr)
        assert result.returncode == 0, result.stderr
        rows = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
        assert len(rows) == (15 if name == 'gun' else 16)
        print(name, len(rows), 'public contract observations', flush=True)


def benchmark(trials):
    cases = [('buffered', n, 4) for n in (1, 10, 100, 1000)]
    cases += [('bounded', 1000, 4), ('buffered', 1000, 100), ('large', 1, 4), ('slow', 1, 4), ('mixed', 1000, 4)]
    results = []
    with (OUT / 'benchmark.jsonl').open('w') as output:
        for trial in range(1, trials + 1):
            # Alternate client order across repetitions, with a fresh VM per case.
            names = ('gun', 'dream') if trial % 2 else ('dream', 'gun')
            for scenario, count, cap in cases:
                for name in names:
                    args = ['gleam', 'run', '-m', 'comparison', '--', name, scenario, str(count), str(cap), str(trial)]
                    try:
                        done = subprocess.run(args, cwd=RUNNER, capture_output=True, text=True, timeout=100)
                        stem = f'bench-{trial}-{name}-{scenario}-{count}-{cap}'
                        (OUT / f'{stem}.stderr').write_text(done.stderr)
                        rows = [json.loads(line) for line in done.stdout.splitlines() if line.startswith('{')]
                        assert done.returncode == 0 and len(rows) == 1, done.stderr + done.stdout
                        row = rows[0]
                        assert row['failures'] == 0, row
                        expected = 33554432 + (count * 3 if scenario == 'mixed' else 0) if scenario in ('large', 'slow', 'mixed') else count * 3
                        assert row['bytes'] == expected, row
                    except (subprocess.TimeoutExpired, AssertionError) as error:
                        row = dict(client=name, scenario=scenario, requests=count, connection_cap=cap, trial=str(trial), error=str(error)[:3000])
                    output.write(json.dumps(row) + '\n'); output.flush(); results.append(row)
                    print(name, scenario, count, cap, trial, 'FAIL' if 'error' in row else f"{row['elapsed_us']/1000:.2f} ms; {row['connections']} connections", flush=True)
    summarize(results)
    return all('error' not in row for row in results)


def summarize(rows):
    groups = collections.defaultdict(list)
    for row in rows:
        groups[(row['scenario'], row['requests'], row['connection_cap'], row['client'])].append(row)
    summary = []
    for (scenario, count, cap, client), trials in groups.items():
        good = [row for row in trials if 'error' not in row]
        metrics = {}
        if good:
            for key in ('elapsed_us', 'p50_us', 'p95_us', 'p99_us', 'connections', 'peak_vm_bytes',
                        'peak_total_mailbox', 'peak_one_mailbox', 'peak_processes', 'peak_ports'):
                values = [row[key] for row in good]
                metrics[key] = dict(median=statistics.median(values), min=min(values), max=max(values))
        summary.append(dict(scenario=scenario, requests=count, connection_cap=cap, client=client,
                            trials=len(trials), failed_trials=len(trials)-len(good), metrics=metrics))
    (OUT / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')


def main():
    global OUT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('mode', choices=['all', 'bench', 'contracts', 'upstream', 'prepare', 'summary'], nargs='?', default='all')
    parser.add_argument('--trials', type=int, default=3)
    parser.add_argument('--output', type=Path, default=OUT,
                        help='Evidence directory; use a new directory to preserve an earlier comparison.')
    args = parser.parse_args()
    OUT = args.output.resolve()
    OUT.mkdir(parents=True, exist_ok=True)
    assert args.trials > 0
    if args.mode == 'summary':
        summarize([json.loads(line) for line in (OUT / 'benchmark.jsonl').read_text().splitlines()])
        return
    prepare()
    success = True
    if args.mode in ('all', 'upstream'): success = upstream()
    if args.mode in ('all', 'contracts'): contracts()
    if args.mode in ('all', 'bench'): success = benchmark(args.trials) and success
    raise SystemExit(0 if success else 1)

if __name__ == '__main__':
    main()
