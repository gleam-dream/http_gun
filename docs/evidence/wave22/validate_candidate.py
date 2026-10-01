from pathlib import Path
import subprocess, shutil, tempfile, sys
candidate=Path('/private/tmp/http-gun-sinal-bn2b5vph/sinal')
with tempfile.TemporaryDirectory(prefix='sinal-candidate-gate-') as temp:
 root=Path(temp)
 for name in ['src','test','dev','gleam.toml','manifest.toml','README.md']:
  source=candidate/name
  if source.is_dir(): shutil.copytree(source,root/name)
  else: shutil.copy2(source,root/name)
 shutil.copytree(candidate/'build/packages',root/'build/packages')
 def run(argv):
  print('+', ' '.join(argv), flush=True)
  subprocess.run(argv,cwd=root,check=True,timeout=90)
 run(['gleam','--version'])
 run(['erl','-noshell','-eval','io:format("OTP ~s ERTS ~s~n",[erlang:system_info(otp_release),erlang:system_info(version)]),halt().'])
 run(['gleam','format','--check','src','test'])
 run(['gleam','check'])
 run(['gleam','build','--warnings-as-errors'])
 run(['gleam','test'])
 out=root/'ffi-check'; out.mkdir()
 run(['erlc','-Werror','-o',str(out),*[str(p) for folder in ['src','test'] for p in (root/folder).glob('*.erl')]])
 run(['python3',str(root/'dev/check_forwarder.py')])
 print('CANDIDATE GATE PASSED',flush=True)
