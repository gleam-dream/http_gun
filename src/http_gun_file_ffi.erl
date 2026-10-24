%% Primitives missing from the selected filesystem libraries. No file IO policy.
-module(http_gun_file_ffi).
-export([directory_name/1, remove_directory/1, remove_staging/1]).
directory_name(Destination) ->
    Suffix = integer_to_binary(erlang:unique_integer([positive, monotonic])),
    Pid = list_to_binary(os:getpid()),
    <<Destination/binary, ".http-gun-", Pid/binary, "-", Suffix/binary>>.
remove_directory(Path) -> file:del_dir(Path), nil.
%% Removes the staging directory and the entries directly inside it. It never
%% recurses: an entry that is a non-empty directory stays, and so does the
%% staging directory. Every failure is ignored; the caller has no recovery.
remove_staging(Path) ->
    case file:list_dir_all(Path) of
        {ok, Names} ->
            lists:foreach(fun (Name) ->
                                  Entry = filename:join(Path, Name),
                                  case file:delete(Entry) of
                                      ok -> ok;
                                      {error, _} -> file:del_dir(Entry)
                                  end
                          end,
                          Names);
        {error, _} -> ok
    end,
    file:del_dir(Path),
    nil.
