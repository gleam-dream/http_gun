#!/bin/sh
set -eu
root=$(pwd)
for runtime in otp28 otp27; do
  out="docs/evidence/wave28/runtimes/$runtime"
  mkdir -p "$out"
  nix develop "path:$root#$runtime" --command sh -c 'gleam --version; erl -noshell -eval '\''io:format("OTP ~s ERTS ~s~n",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'\''; sh dev/gate full' > "$out/full.log" 2>&1
  cp build/evidence/load.jsonl build/evidence/recording.jsonl build/evidence/batch.jsonl "$out/"
  cp -R build/evidence/nghttpd "$out/"
  echo "$runtime full gate passed"
done
