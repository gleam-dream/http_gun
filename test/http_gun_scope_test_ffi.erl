-module(http_gun_scope_test_ffi).
-export([raised/1, fixture/1, remove/1]).
raised(Fun) -> try Fun(), false catch error:scope_probe -> true end.

fixture(Bytes) ->
    Path = http_gun_test_server:temp_path(),
    ok = file:write_file(Path, Bytes),
    Path.
remove(Path) -> file:delete(Path), nil.
