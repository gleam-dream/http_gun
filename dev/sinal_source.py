#!/usr/bin/env python3
"""Materialize the pinned, unpublished Sinal source for isolated package gates."""
import argparse
import gzip
import io
import subprocess
import hashlib
import json
from pathlib import Path
import sys
import tarfile


def verify(source):
    artifacts = Path(__file__).resolve().parent / "dependencies"
    metadata = json.loads((artifacts / "sinal.json").read_text())
    source = Path(source)
    expected_src = {name for name in metadata["files"] if name.startswith("src/")}
    actual_src = {str(p.relative_to(source)) for p in (source / "src").rglob("*") if p.is_file()}
    assert actual_src == expected_src, "Sinal source set differs from pinned snapshot"
    for name, expected in metadata["files"].items():
        assert hashlib.sha256((source / name).read_bytes()).hexdigest() == expected, f"Sinal snapshot differs: {name}"


def extract(destination):
    artifacts = Path(__file__).resolve().parent / 'dependencies'
    metadata = json.loads((artifacts / 'sinal.json').read_text())
    archive = artifacts / 'sinal.tar.gz'
    assert hashlib.sha256(archive.read_bytes()).hexdigest() == metadata['archive_sha256']
    destination = Path(destination)
    destination.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive) as source:
        source.extractall(destination, filter='data')
    for name, expected in metadata['files'].items():
        assert hashlib.sha256((destination / name).read_bytes()).hexdigest() == expected, name


def snapshot(source):
    """Freeze the canonical checkout after validation; never mutate its source."""
    source = Path(source).resolve()
    artifacts = Path(__file__).resolve().parent / 'dependencies'
    names = ['gleam.toml', 'manifest.toml', 'README.md', 'LICENSE']
    names += [str(p.relative_to(source)) for p in (source / 'src').rglob('*') if p.is_file()]
    if (source / 'NOTICE').exists():
        names.append('NOTICE')
    names.sort()
    buffer = io.BytesIO()
    hashes = {}
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.PAX_FORMAT) as archive:
        for name in names:
            data = (source / name).read_bytes()
            hashes[name] = hashlib.sha256(data).hexdigest()
            entry = tarfile.TarInfo(name)
            entry.size, entry.mode, entry.mtime = len(data), 0o644, 0
            archive.addfile(entry, io.BytesIO(data))
    data = gzip.compress(buffer.getvalue(), mtime=0)
    metadata = {
        'name': 'sinal',
        'revision': subprocess.check_output(['git', '-C', str(source), 'rev-parse', 'HEAD'], text=True).strip(),
        'status': subprocess.check_output(['git', '-C', str(source), 'status', '--porcelain'], text=True),
        'files': hashes,
        'license': 'Apache-2.0; original LICENSE and manifest preserved',
        'source': 'Canonical local Sinal checkout, including owner-authorized generic forwarder correction; no HTTP-specific code.',
        'archive_sha256': hashlib.sha256(data).hexdigest(),
    }
    artifacts.mkdir(parents=True, exist_ok=True)
    (artifacts / 'sinal.tar.gz').write_bytes(data)
    (artifacts / 'sinal.json').write_text(json.dumps(metadata, indent=2) + '\n')
    verify(source)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('path', type=Path)
    parser.add_argument('--snapshot', action='store_true', help='After validation, replace pinned artifacts from this canonical source')
    args = parser.parse_args()
    if args.snapshot:
        snapshot(args.path)
    else:
        if args.path.exists():
            parser.error('Extraction requires a new directory, avoiding mixed dependency sources')
        extract(args.path)
