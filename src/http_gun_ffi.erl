%% Narrow transport/runtime boundary. No client state or server loops.
-module(http_gun_ffi).
-export([start/0, open/8, request/5, credit/3, cancel/2, close/1, now/0, scoped/2, decode/1]).
-export([on_exception/2, cause/1]).
-export([parse_address/1, lookup/3]).
parse_address(Host) ->
    case inet:parse_strict_address(binary_to_list(Host)) of
        {ok, Address} -> {ok, address(Address)};
        {error, _} -> {error, nil}
    end.
address({A,B,C,D}) -> {ipv4,A,B,C,D};
address({A,B,C,D,E,F,G,H}) -> {ipv6,A,B,C,D,E,F,G,H}.
start() ->
    case application:ensure_all_started(gun) of
        {ok, _} -> {ok, nil};
        {error, _} -> {error, nil}
    end.
lookup(Host, Family, Timeout) ->
    case inet:getaddrs(binary_to_list(Host), Family, Timeout) of
        {ok, Addresses} -> {ok, lists:map(fun address/1, Addresses)};
        {error, nxdomain} -> {ok, []};
        {error, _} -> {error, nil}
    end.
ip({ipv4,A,B,C,D}) -> {A,B,C,D};
ip({ipv6,A,B,C,D,E,F,G,H}) -> {A,B,C,D,E,F,G,H}.
open(Address, ServerName, Port, Tls, Protocol, Trust, Timeout, HeaderCount) ->
    try
        Protocols = case {Tls, Protocol} of
            {true, require_http2} -> [http2, http];
            {false, require_http2} -> [http2];
            {true, prefer_http2} -> [http2, http];
            _ -> [http]
        end,
        Base = #{retry => 0, protocols => Protocols, connect_timeout => Timeout,
            domain_lookup_timeout => Timeout, tls_handshake_timeout => Timeout,
            tcp_opts => [{send_timeout, Timeout}, {send_timeout_close, true}],
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
                Name = case ServerName of
                    none -> [];
                    {some, Host} -> [{server_name_indication, binary_to_list(Host)}]
                end,
                Base#{transport => tls, tls_opts => [Ca, {verify, verify_peer},
                    {send_timeout, Timeout}, {send_timeout_close, true},
                    {customize_hostname_check, [{match_fun, public_key:pkix_verify_hostname_match_fun(https)}]} | Name]}
        end,
        case gun:open(ip(Address), Port, Options) of
            {ok, Pid} -> {ok, Pid};
            {error, Reason} -> {error, cause(Reason)}
        end
    catch _:Caught -> {error, cause(Caught)} end.
request(Pid, Method, Path, Headers, Body) ->
    try {ok, gun:request(Pid, Method, Path, Headers, Body, #{reply_to => self(), flow => 1})}
    catch _:Reason -> {error, cause(Reason)} end.
credit(Pid, Ref, Amount) -> gun:update_flow(Pid, Ref, Amount), nil.
cancel(Pid, Ref) -> gun:cancel(Pid, Ref), nil.
close(Pid) -> try gun:close(Pid) catch _:_ -> ok end, nil.
now() -> erlang:monotonic_time(millisecond).
scoped(Run, Cleanup) -> try Run() after Cleanup() end.
on_exception(Run, Cleanup) ->
    try Run() catch Class:Reason:Stack -> Cleanup(), erlang:raise(Class, Reason, Stack) end.
decode({gun_up, P, http}) -> {up, P, h1};
decode({gun_up, P, http2}) -> {up, P, h2};
decode({gun_down, P, _, Reason, _}) -> {down, P, cause(Reason)};
decode({gun_error, P, Reason}) -> {down, P, cause(Reason)};
decode({gun_notify, P, settings_changed, Settings}) ->
    {capacity, P, maps:get(max_concurrent_streams, Settings, 2147483647)};
decode({gun_response, _, R, Fin, Status, Headers}) -> {head, R, Fin =:= fin, Status, Headers};
decode({gun_data, _, R, Fin, Bytes}) -> {data, R, Fin =:= fin, Bytes};
decode({gun_trailers, _, R, Headers}) -> {trailers, R, Headers};
decode({gun_error, _, R, Reason}) -> {failed, R, cause(Reason)};
decode({gun_inform, _, R, _, H}) -> {inform, R, H};
decode({gun_upgrade, _, R, _, _}) -> {failed, R, unexpected_protocol};
decode(_) -> ignore.

%% Classify supported runtime reasons; never format arbitrary peer/runtime terms.
cause({shutdown, Reason}) -> cause(Reason);
cause({error, Reason}) -> cause(Reason);
cause(nxdomain) -> name_resolution_failed;
cause(econnrefused) -> connection_refused;
cause(econnreset) -> connection_reset;
cause(closed) -> peer_closed;
cause(normal) -> peer_closed;
cause(closing) -> peer_draining;
cause(timeout) -> transport_timeout;
cause(etimedout) -> transport_timeout;
cause({tls_alert, {Alert, _}}) when Alert =:= unknown_ca; Alert =:= bad_certificate;
    Alert =:= certificate_expired; Alert =:= certificate_revoked;
    Alert =:= certificate_unknown -> certificate_rejected;
cause({tls_alert, _}) -> tls_failed;
cause({bad_cert, _}) -> certificate_rejected;
cause({stream_error, _, _}) -> protocol_error;
cause({connection_error, _, _}) -> protocol_error;
cause(_) -> unknown_transport.
