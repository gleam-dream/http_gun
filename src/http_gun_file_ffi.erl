%% Primitives missing from the selected filesystem libraries. No file IO policy.
-module(http_gun_file_ffi).
-export([directory_name/1, remove_directory/1]).
directory_name(Destination) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Pid = list_to_binary(os:getpid()),
    <<Destination/binary, ".http-gun-", Pid/binary, "-", Suffix/binary>>.
remove_directory(Path) -> file:del_dir(Path), nil.
