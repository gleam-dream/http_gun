%% Narrow transport/runtime boundary. No client state or server loops.
-module(http_gun_ffi).
-export([start/0, open/7, request/5, credit/3, cancel/2, close/1, now/0, scoped/2, decode/1]).
-export([on_exception/2]).
start() ->
    case application:ensure_all_started(gun) of
        {ok, _} -> {ok, nil};
        {error, _} -> {error, nil}
    end.
open(Host, Port, Tls, Protocol, Trust, Timeout, HeaderCount) ->
    try
        Protocols = case {Tls, Protocol} of
            {true, require_http2} -> [http2, http];
            {false, require_http2} -> [http2];
            {true, prefer_http2} -> [http2, http];
            _ -> [http]
        end,
        Base = #{retry => 0, protocols => Protocols, connect_timeout => Timeout,
            domain_lookup_timeout => Timeout, tls_handshake_timeout => Timeout,
            http_opts => #{flow => 1, max_headers => HeaderCount},
            http2_opts => #{flow => 1, notify_settings_changed => true,
                %% HPACK includes :status; application header counts do not.
                max_headers => HeaderCount + 1,
                initial_stream_window_size => 16384,
                initial_connection_window_size => 65535}},
        Options = case Tls of
            false -> Base#{transport => tcp};
            true ->
                Ca = case Trust of
                    system_trust -> {cacerts, public_key:cacerts_get()};
                    {custom_ca, Path} -> {cacertfile, binary_to_list(Path)}
                end,
                Base#{transport => tls, tls_opts => [Ca, {verify, verify_peer},
                    {server_name_indication, binary_to_list(Host)},
                    {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]}]}
        end,
        case gun:open(binary_to_list(Host), Port, Options) of
            {ok, Pid} -> {ok, Pid};
            {error, _} -> {error, nil}
        end
    catch _:_ -> {error, nil} end.
request(Pid, Method, Path, Headers, Body) ->
    try {ok, gun:request(Pid, Method, Path, Headers, Body, #{reply_to => self(), flow => 1})}
    catch _:_ -> {error, nil} end.
credit(Pid, Ref, Amount) -> gun:update_flow(Pid, Ref, Amount), nil.
cancel(Pid, Ref) -> gun:cancel(Pid, Ref), nil.
close(Pid) -> try gun:close(Pid) catch _:_ -> ok end, nil.
now() -> erlang:monotonic_time(millisecond).
scoped(Run, Cleanup) -> try Run() after Cleanup() end.
on_exception(Run, Cleanup) ->
    try Run() catch Class:Reason:Stack -> Cleanup(), erlang:raise(Class, Reason, Stack) end.
decode({gun_up, P, http}) -> {up, P, h1};
decode({gun_up, P, http2}) -> {up, P, h2};
decode({gun_down, P, _, _, _}) -> {down, P};
decode({gun_error, P, _}) -> {down, P};
decode({gun_notify, P, settings_changed, Settings}) ->
    {capacity, P, maps:get(max_concurrent_streams, Settings, 2147483647)};
decode({gun_response, _, R, Fin, Status, Headers}) -> {head, R, Fin =:= fin, Status, Headers};
decode({gun_data, _, R, Fin, Bytes}) -> {data, R, Fin =:= fin, Bytes};
decode({gun_trailers, _, R, Headers}) -> {trailers, R, Headers};
decode({gun_error, _, R, _}) -> {failed, R};
decode({gun_inform, _, R, _, H}) -> {inform, R, H};
decode({gun_upgrade, _, R, _, _}) -> {failed, R};
decode(_) -> ignore.
