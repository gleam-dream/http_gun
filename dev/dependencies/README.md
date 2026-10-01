# Selected Sinal source for independent gates

Sinal is unpublished. Development and the current downstream share `../sinal`.
The normal gate extracts this exact archive once into that path within a private
workspace. It does not depend on a sibling checkout or select a second runtime.
The historical LLM archive's Sinal is removed after provenance verification,
then replaced with this source before compilation.

`sinal.json` identifies the canonical Git baseline, dirty status, each selected
file hash and archive SHA256. Original Apache-2.0 LICENSE is included. The two
source directories must match; the gate refuses drift when the sibling exists.

After generic changes are applied and validated in Sinal, refresh explicitly:

```
./dev/env python3 dev/sinal_source.py --snapshot ../sinal
```

No independent edits inside the archive. Regeneration uses sorted files,
normalized metadata and fixed gzip/tar timestamps. Once a compatible immutable
release is available, replace this temporary source arrangement in HTTP Gun and
its consumers together. No release or upstream contact is authorized here.
