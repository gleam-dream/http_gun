"""Public batch regression: tenfold input must not exhibit quadratic growth.

Use warmed fresh VMs, median of three trials and generous noise allowance.
This is a local scaling check, never an absolute throughput or latency SLA.
"""
import json
import pathlib
import statistics
import subprocess
import sys

output = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else 'build/evidence/batch.jsonl')
output.parent.mkdir(parents=True, exist_ok=True)
rows = []
for trial in range(3):
    run = subprocess.run(['gleam', 'run', '-m', 'http_gun_batch_benchmark'], check=True, text=True, stdout=subprocess.PIPE)
    for line in run.stdout.splitlines():
        row = json.loads(line)
        rows.append(dict(trial=trial, **row))
output.write_text(''.join(json.dumps(row) + '\n' for row in rows))
medians = {n: statistics.median(r['elapsed_us'] for r in rows if r['requests'] == n) for n in {r['requests'] for r in rows}}
print(json.dumps(dict(median_us=medians, evidence=str(output))))
assert medians[5000] < medians[500] * 15 + 50_000, 'Public batch shows excessive growth for tenfold input'
