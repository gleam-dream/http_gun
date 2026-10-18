# Selected Sinal source for independent gates

A frozen archive of the Sinal source that the gate extracts into a private
workspace. `sinal.json` records the Git baseline, dirty status, file hashes and
archive SHA-256; the Apache-2.0 LICENSE is included.

Refresh after Sinal changes are validated:

```sh
./dev/env python3 dev/sinal_source.py --snapshot ../sinal
```

Make no edits inside the archive.
