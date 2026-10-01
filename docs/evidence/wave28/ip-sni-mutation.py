"""Negative control for the IP-literal SAN test, confined to a temporary copy."""
from pathlib import Path
import json
import shutil
import subprocess
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root/'dev'))
from sinal_source import extract
out = root/'docs/evidence/wave28'
with tempfile.TemporaryDirectory(prefix='http-gun-ip-sni-mutation-') as work:
    work = Path(work)
    package = work/'http_gun'
    package.mkdir()
    for name in ['src','test','gleam.toml','manifest.toml']:
        source = root/name
        if source.is_dir(): shutil.copytree(source,package/name)
        else: shutil.copy2(source,package/name)
    extract(work/'sinal')
    ffi = package/'src/http_gun_ffi.erl'
    source = ffi.read_text()
    assert source.count('none -> [];') == 1
    ffi.write_text(source.replace('none -> [];','none -> [{server_name_indication, disable}];'))
    with (out/'ip-sni-mutation.log').open('w') as log:
        result = subprocess.run(['gleam','run','-m','http_gun_destination_test'],cwd=package,stdout=log,stderr=subprocess.STDOUT)
    log = (out/'ip-sni-mutation.log').read_text()
    caught = result.returncode != 0 and 'ip_literal_tls_checks_ip_san_test' in log and 'Ok(Buffered(Response(200' in log
    (out/'ip-sni-mutation.json').write_text(json.dumps({'mutation':'IP-literal SNI omitted -> disable, disposable copy only','exit':result.returncode,'failed_for_wrong_certificate_acceptance':caught},indent=2)+'\n')
    assert caught, 'Mutation must fail for acceptance of the trusted wrong-host certificate'
print('Negative control passed: IP-literal test detects SNI=disable accepting a wrong-host certificate.')
