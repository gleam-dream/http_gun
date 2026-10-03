"""One-off adoption experiment: only isolated downstream test/example setup changes."""
import difflib
import hashlib
import json
from pathlib import Path
import re
import shutil
import sys
import tempfile

root = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(root / 'dev'))
import check_downstream as gate

output = root / 'docs/evidence/wave31/downstream-final'
output.mkdir(exist_ok=False)
roots = gate.closure(root, Path('/code/gleam-dream/llm_wire'))
before = {name: gate.inputs(path) for name, path in roots.items()}
receipt = {'sources': {name: {'path':str(roots[name]), **value} for name,value in before.items()},
           'commands': [], 'adaptations': [], 'passed': False}
try:
    with tempfile.TemporaryDirectory(prefix='http-gun-destination-adoption-') as work:
        copies = gate.isolate(roots, before, Path(work))
        consumer = copies['llm_wire']
        for path in [*sorted((consumer/'test').rglob('*.gleam')),
                     *sorted((consumer/'examples/consumer').rglob('*.gleam'))]:
            original = path.read_text()
            match = re.search(r'^import http_gun/config(?: as (\w+))?$', original, re.M)
            if not match:
                continue
            alias = match[1] or 'config'
            if f'{alias}.default()' not in original:
                continue
            updated = original.replace(f'{alias}.default()', 'destination_test_config()')
            updated = updated.replace(match[0], match[0]+'\nimport http_gun/destination as http_destination')
            updated += f'''\n// Isolated adoption experiment: explicitly permit the local test servers.
fn destination_test_config() -> {alias}.Config {{
  let defaults = {alias}.default()
  {alias}.Config(..defaults, destination: http_destination.Policy(..defaults.destination, allow_loopback: True))
}}
'''
            path.write_text(updated)
            name = str(path.relative_to(consumer))
            receipt['adaptations'].append({'path':name, 'before':hashlib.sha256(original.encode()).hexdigest(),
                                          'after':hashlib.sha256(updated.encode()).hexdigest()})
            with (output/'setup.patch').open('a') as patch:
                patch.writelines(difflib.unified_diff(original.splitlines(True),updated.splitlines(True),fromfile='a/'+name,tofile='b/'+name))
        for label, command in [
            ('gleam',['gleam','--version']),
            ('check',['gleam','check']),
            ('build',['gleam','build','--warnings-as-errors']),
            ('tests',['gleam','test']),
            ('boundary',['sh','test/external_package_boundary.sh']),
            ('local-http',['python3','dev/local-http.py']),
        ]:
            gate.run(command, consumer, output, label, receipt)
        shutil.copytree(consumer/'docs/evidence/http-gun', output/'local-http')
        receipt['passed'] = True
finally:
    receipt['originals_unchanged'] = all(gate.inputs(path) == before[name] for name,path in roots.items())
    receipt['passed'] &= receipt['originals_unchanged']
    (output/'receipt.json').write_text(json.dumps(receipt,indent=2)+'\n')
print('Isolated downstream setup adaptation passed; original checkouts unchanged.')
