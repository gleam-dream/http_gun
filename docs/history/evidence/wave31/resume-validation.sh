#!/bin/sh
# Sequential retry after the retained Hex API rate-limit failures.
set -eu
root=$(pwd)
out=docs/evidence/wave31/runtimes/otp27
mkdir -p "$out"
nix develop "path:$root#otp27" --command sh -c 'gleam --version; erl -noshell -eval '\''io:format("OTP ~s ERTS ~s~n",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'\''; sh dev/gate full' > "$out/full.log" 2>&1
cp build/evidence/load.jsonl build/evidence/recording.jsonl build/evidence/batch.jsonl "$out/"
cp -R build/evidence/nghttpd "$out/"
echo 'OTP27 full gate passed'
./dev/env python3 docs/evidence/wave31/adapted_downstream.py > docs/evidence/wave31/downstream-final-driver.log 2>&1
echo 'Isolated LLM Wire gate passed'
