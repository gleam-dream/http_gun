#!/bin/sh
set -eu
for runtime in otp28 otp27; do
  nix develop "path:/code/gleam-dream/http_gun#$runtime" --command sh -c 'gleam --version; erl -noshell -eval '\''io:format("OTP ~s ERTS ~s~n",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'\''; sh dev/gate full' > "build/evidence/$runtime.log" 2>&1
  cp build/evidence/load.jsonl "build/evidence/$runtime-load.jsonl"
  cp build/evidence/recording.jsonl "build/evidence/$runtime-recording.jsonl"
  cp build/evidence/batch.jsonl "build/evidence/$runtime-batch.jsonl"
  mkdir -p "build/evidence/$runtime-nghttpd"
  cp -R build/evidence/nghttpd/. "build/evidence/$runtime-nghttpd"
  echo "$runtime full gate passed"
done
