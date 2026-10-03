"""Recheck Warden's retained experiment against this working tree, in isolation."""
import difflib
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'dev'))
import check_downstream as gate

warden = Path('/code/gleam-dream/warden')
output = root / 'docs/evidence/wave31/warden-final'
output.mkdir(exist_ok=False)
roots = {'http_gun': root, 'warden': warden, 'sinal': root.parent / 'sinal'}
before = {name: gate.inputs(path) for name, path in roots.items()}
reference = warden / 'docs/evidence/http-gun-adoption/experiment'
reference_files = {p.name: hashlib.sha256(p.read_bytes()).hexdigest()
                   for p in reference.iterdir() if p.is_file()}
receipt = {'sources': before, 'reference_files': reference_files, 'commands': [],
           'scope': 'isolated adapter, no provider endpoints, unchanged transport tests'}

def run(command, cwd, label):
    with (output / (label + '.log')).open('wb') as log:
        result = subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT,
                                timeout=600)
    receipt['commands'].append({'argv':command, 'exit':result.returncode, 'log':label+'.log'})
    print(label, result.returncode, flush=True)
    return result.returncode

try:
    with tempfile.TemporaryDirectory(prefix='http-gun-warden-') as directory:
        work = Path(directory)
        for name, source in roots.items():
            for relative in before[name]['files']:
                dest = work / name / relative
                dest.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source / relative, dest)
        target = work / 'warden'
        manifest = target / 'gleam.toml'
        manifest.write_text(manifest.read_text().replace('[dependencies]', '[dependencies]\nhttp_gun = { path = "../http_gun" }\ngleam_http = ">= 4.4.0 and < 5.0.0"'))
        adapter = (reference / 'transport.gleam').read_text()
        updated = adapter
        a = updated.index('// Trust (EXPERIMENT:')
        b = updated.index('// Destination classification', a)
        updated = updated[:a]+'''// Trust: pass DER anchors directly, without a temporary file.
fn trust_of(trust: Trust) -> Result(config.Trust, Failure) {
  case trust {
    SystemTrust -> Ok(config.SystemTrust)
    Anchors([]) -> not_sent(NoTrustAnchors)
    Anchors(ders) -> Ok(config.Anchors(ders))
  }
}

'''+updated[b:]
        for imp in ['import gleam/crypto\n', 'import gleam/dynamic.{type Dynamic}\n',
                    'import gleam/dynamic/decode\n', 'import gleam/erlang/charlist\n']:
            updated = updated.replace(imp, '')
        updated = updated.replace('error.ProtocolError | error.UnexpectedProtocol -> MalformedResponse',
                                  'error.ProtocolError | error.UnexpectedProtocol -> MalformedResponse\n        error.HeaderLimitReached -> HeadersTooLarge')
        updated = updated.replace('//// in-memory trust anchors are written to a temporary PEM file because\n//// HTTP Gun only accepts a CA file path (gap G2).',
                                  '//// trust anchors use the public config.Anchors variant directly.')
        (target / 'src/warden/internal/transport.gleam').write_text(updated)
        (output/'adapter.patch').write_text(''.join(difflib.unified_diff(adapter.splitlines(True), updated.splitlines(True),fromfile='reference/transport.gleam',tofile='isolated/transport.gleam')))
        for name in ['gun_probe_test.gleam', 'gun_security_probe_test.gleam', 'gun_probe_ffi.erl']:
            shutil.copy2(reference/name, target/'test'/name)
        assert run(['sh', 'scripts/test-pki'], target, 'pki') == 0
        # IPv6 probe identity, signed by the disposable CA generated above.
        pki = target/'build/test-pki'
        (pki/'ipv6.ext').write_text('subjectAltName=IP:::1,IP:127.0.0.1\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nbasicConstraints=CA:FALSE\n')
        assert run(['openssl','req','-newkey','rsa:2048','-nodes','-keyout','ipv6.key','-out','ipv6.csr','-subj','/CN=ipv6'],pki,'ipv6-key') == 0
        assert run(['openssl','x509','-req','-in','ipv6.csr','-CA','ca.pem','-CAkey','ca.cakey','-set_serial','19','-out','ipv6.pem','-days','30','-sha256','-extfile','ipv6.ext'],pki,'ipv6-cert') == 0
        assert run(['gleam','format','src/warden/internal/transport.gleam'],target,'format') == 0
        assert run(['gleam','build','--warnings-as-errors'],target,'build') == 0
        for name, spec in [('transport',"'warden@transport_test'"), ('security','gun_security_probe_test'), ('table','{gun_probe_test,framing_and_bounds_table_test}')]:
            run(['sh','-c', 'erl -noshell -pa build/dev/erlang/*/ebin -eval "case eunit:test({timeout,300,'+spec+'}, [verbose]) of ok -> halt(0); _ -> halt(1) end."'],target,name)
        run(['gleam','test'],target,'fast-suite')
        run(['sh','scripts/negative'],target,'boundary')
        run(['gleam','test'],target/'consumer','consumer')
        receipt['transport_tests_unchanged'] = (target/'test/warden/transport_test.gleam').read_bytes() == (warden/'test/warden/transport_test.gleam').read_bytes()
finally:
    receipt['originals_unchanged'] = all(gate.inputs(path)==before[name] for name,path in roots.items())
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
