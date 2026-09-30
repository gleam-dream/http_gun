-module(http_gun_recording_fault_test_ffi).
-include_lib("kernel/include/file.hrl").
-export([break_file/1, stall_file/1, release/1, private/1]).
private(Destination) ->
    [Path] = filelib:wildcard(binary_to_list(Destination) ++ ".http-gun-*"),
    {ok,Info} = file:read_file_info(Path),
    (Info#file_info.mode band 8#777) =:= 8#700.
spool(Destination) ->
    [Path] = filelib:wildcard(binary_to_list(Destination) ++ ".http-gun-*/0.json"),
    Path.
break_file(Destination) ->
    Path = spool(Destination),
    ok = file:delete(Path),
    ok = file:make_dir(Path),
    nil.
stall_file(Destination) ->
    Path = spool(Destination),
    ok = file:delete(Path),
    Executable = os:find_executable("mkfifo"),
    Port = open_port({spawn_executable, Executable}, [{args, [Path]}, exit_status]),
    receive {Port, {exit_status, 0}} -> list_to_binary(Path)
    after 2000 -> error(mkfifo_timeout) end.
release(Path) ->
    spawn(fun() ->
        case file:open(Path, [read, raw, binary]) of
            {ok, F} -> file:close(F), file:delete(Path);
            _ -> ok
        end
    end),
    nil.
