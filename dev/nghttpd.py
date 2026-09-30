"""Independent loopback HTTP/2 server; cleanup only the process we started."""
import argparse
import json
from pathlib import Path
import re
import socket
import subprocess
import tempfile
import threading
import hashlib
import time

parser = argparse.ArgumentParser()
parser.add_argument('--soak-seconds', type=int, default=0)
args = parser.parse_args()
assert 0 <= args.soak_seconds <= 600
root = Path.cwd()
evidence = root / 'build/evidence/nghttpd'
evidence.mkdir(parents=True, exist_ok=True)
version = subprocess.check_output(['nghttpd', '--version'], text=True).strip()
with tempfile.TemporaryDirectory(prefix='http-gun-nghttpd-') as temporary:
    files = Path(temporary)
    (files / 'bytes').write_bytes(bytes(range(256)))
    with (files / 'large').open('wb') as output:
        for _ in range(32768):
            output.write(bytes(range(256)) * 4)
    with socket.socket() as reserve:
        reserve.bind(('127.0.0.1', 0))
        port = reserve.getsockname()[1]
    (evidence / 'port').write_text(str(port))
    (evidence / 'duration').write_text(str(args.soak_seconds))
    command = ['nghttpd', '-a', '127.0.0.1', '-v', '-m', '8', '--echo-upload',
               '--trailer', 'x-final: yes', '-d', str(files), str(port),
               str(root / 'test/fixtures/localhost.key'), str(root / 'test/fixtures/localhost.crt')]
    connection_ids = set()
    resets = [0]
    log_hash = hashlib.sha256()
    log_bytes = [0]
    def observe(pipe):
        # Count every server event; retain only a bounded diagnostic prefix.
        with (evidence / 'server.log').open('wb') as log:
            for raw in iter(pipe.readline, b''):
                log_hash.update(raw)
                if log_bytes[0] < 262144:
                    log.write(raw[:262144 - log_bytes[0]])
                log_bytes[0] += len(raw)
                line = raw.decode('utf-8', errors='replace')
                found = re.search(r'\[id=(\d+)\].*recv HEADERS frame', line)
                if found:
                    connection_ids.add(found.group(1))
                if 'recv RST_STREAM frame' in line:
                    resets[0] += 1
    server = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    observer = threading.Thread(target=observe, args=(server.stdout,))
    observer.start()
    try:
        deadline = time.monotonic() + 5
        while True:
            assert server.poll() is None, 'nghttpd exited before readiness'
            try:
                with socket.create_connection(('127.0.0.1', port), timeout=.2):
                    break
            except OSError:
                if time.monotonic() > deadline:
                    raise
                time.sleep(.02)
        with (evidence / 'http-gun.jsonl').open('w') as output:
            subprocess.run(['gleam', 'run', '-m', 'http_gun_interop'], stdout=output, check=True)
    finally:
        server.terminate()
        try:
            server.wait(timeout=5)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait()
        observer.join(timeout=5)
        assert not observer.is_alive(), 'Server log observer did not stop'
    assert len(connection_ids) == 1, ('Expected all request streams on one TLS connection', connection_ids)
    assert resets[0] >= 2, 'Expected client cancellation of large responses'
    rows = [json.loads(line) for line in (evidence / 'http-gun.jsonl').read_text().splitlines()]
    assert {1, 10, 100, 1000} <= {r['requests'] for r in rows if r['scenario'] == 'nghttpd-concurrent'}
    receipt = dict(server=version, server_stream_limit=8, client_connection_limit=1,
                   observed_request_connections=len(connection_ids), resets=resets[0], log_bytes=log_bytes[0], log_sha256=log_hash.hexdigest(),
                   soak_seconds=args.soak_seconds, scenarios=len(rows), result='passed')
    (evidence / 'receipt.json').write_text(json.dumps(receipt, indent=2) + '\n')
    print(json.dumps(receipt))
