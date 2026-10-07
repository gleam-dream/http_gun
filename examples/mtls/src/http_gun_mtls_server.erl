%% Test-only local TLS peer. No production transport implementation is reused.
-module(http_gun_mtls_server).
-export([start/1, stop/1, pem/1, path/1, anchors/0, await_held/0, release/1,
         await_request/0, requests/1]).

path(Name) -> unicode:characters_to_binary(filename:join(os:getenv("HTTP_GUN_MTLS_FIXTURES"), binary_to_list(Name))).
pem(Name) -> {ok, Bytes} = file:read_file(path(Name)), Bytes.
anchors() -> [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(pem(<<"server-ca.crt">>))].
start(Protocol) ->
    {ok, _} = application:ensure_all_started(ssl),
    Owner = self(),
    Pid = spawn(fun() ->
        {ok, L} = ssl:listen(0, [binary, {active, false}, {reuseaddr, true},
            {ip, {127, 0, 0, 1}},
            {versions, case Protocol of h1_tls12 -> ['tlsv1.2']; _ -> ['tlsv1.3'] end},
            {verify, verify_peer}, {fail_if_no_peer_cert, true},
            {cacertfile, binary_to_list(path(<<"client-ca.crt">>))},
            {certfile, binary_to_list(path(<<"server.crt">>))},
            {keyfile, binary_to_list(path(<<"server.key">>))},
            {alpn_preferred_protocols, case Protocol of h2 -> [<<"h2">>]; _ -> [<<"http/1.1">>] end}]),
        {ok, {_, Port}} = ssl:sockname(L),
        Owner ! {mtls_started, self(), Port},
        accept(L, Owner, Protocol)
    end),
    receive {mtls_started, Pid, Port} -> {Port, Pid} after 5000 -> error(mtls_start_timeout) end.
stop(Pid) -> exit(Pid, shutdown), nil.
accept(L, Owner, Protocol) ->
    case ssl:transport_accept(L, 10000) of
        {ok, T} ->
            Pid = spawn_link(fun() -> receive {socket, Socket} ->
                try serve(Socket, Owner, Protocol)
                catch error:{badmatch, {error, closed}} -> ok
                after ssl:close(Socket) end
            end end),
            ok = ssl:controlling_process(T, Pid),
            Pid ! {socket, T},
            accept(L, Owner, Protocol);
        _ -> ssl:close(L)
    end.
serve(T, Owner, Protocol) ->
    case ssl:handshake(T, 5000) of
        {ok, S} ->
            {ok, Der} = ssl:peercert(S),
            [{'Certificate', A, not_encrypted}] = public_key:pem_decode(pem(<<"a.crt">>)),
            Identity = case Der of A -> <<"a">>; _ -> <<"b">> end,
            Id = integer_to_binary(erlang:unique_integer([positive])),
            case Protocol of
                P when P =:= h1; P =:= h1_tls12 -> h1(S, Owner, Identity, Id, <<>>);
                h2 ->
                    case ssl:recv(S, 24, 5000) of
                        {ok, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>} ->
                            ok = ssl:send(S, cow_http2:settings(#{max_concurrent_streams => 10})),
                            h2(S, Owner, Identity, Id, <<>>, cow_hpack:init(), cow_hpack:init());
                        _ -> ssl:close(S)
                    end
            end;
        {error, _} -> ssl:close(T)
    end.
h1(S, Owner, Identity, Id, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\n">>) of
        nomatch ->
            case ssl:recv(S, 0, 5000) of
                {ok, Bytes} -> h1(S, Owner, Identity, Id, <<Buffer/binary, Bytes/binary>>);
                _ -> ssl:close(S)
            end;
        {At, 4} ->
            <<Headers:At/binary, _:4/binary, Rest/binary>> = Buffer,
            [Line | _] = binary:split(Headers, <<"\r\n">>, [global]),
            [_, Path, _] = binary:split(Line, <<" ">>, [global]),
            Owner ! {mtls_request, self(), Path, Identity, Id},
            case Path of
                <<"/loss">> -> ssl:close(S);
                _ ->
                    Close = case Path of <<"/close">> -> <<"Connection: close\r\n">>; _ -> <<>> end,
                    ok = ssl:send(S, [<<"HTTP/1.1 200 OK\r\nContent-Length: 1\r\nX-Connection: ">>, Id, <<"\r\n">>, Close, <<"\r\n">>]),
                    case Path of
                        <<"/held">> -> Owner ! {mtls_held, self()}, receive release -> ok after 5000 -> error(mtls_not_released) end;
                        _ -> ok
                    end,
                    ok = ssl:send(S, Identity),
                    case Path of <<"/close">> -> ssl:close(S); _ -> h1(S, Owner, Identity, Id, Rest) end
            end
    end.
h2(S, Owner, Identity, Id, Buffer, Decode, Encode) ->
    case cow_http2:parse(Buffer) of
        more ->
            case ssl:recv(S, 0, 5000) of
                {ok, Bytes} -> h2(S, Owner, Identity, Id, <<Buffer/binary, Bytes/binary>>, Decode, Encode);
                _ -> ssl:close(S)
            end;
        {ok, {settings, _}, Rest} ->
            ok = ssl:send(S, cow_http2:settings_ack()),
            h2(S, Owner, Identity, Id, Rest, Decode, Encode);
        {ok, {headers, Stream, _, head_fin, Block}, Rest} ->
            {Headers, NextDecode} = cow_hpack:decode(Block, Decode),
            Owner ! {mtls_request, self(), proplists:get_value(<<":path">>, Headers), Identity, Id},
            {Head, NextEncode} = cow_hpack:encode([{<<":status">>, <<"200">>}, {<<"x-connection">>, Id}], Encode),
            ok = ssl:send(S, [cow_http2:headers(Stream, nofin, Head), cow_http2:data(Stream, fin, Identity)]),
            h2(S, Owner, Identity, Id, Rest, NextDecode, NextEncode);
        {ok, _, Rest} -> h2(S, Owner, Identity, Id, Rest, Decode, Encode);
        _ -> ssl:close(S)
    end.
await_held() -> receive {mtls_held, Pid} -> Pid after 5000 -> error(mtls_no_held_exchange) end.
release(Pid) -> Pid ! release, nil.
await_request() -> receive {mtls_request, _, Path, Identity, Id} -> {Path, Identity, Id} after 5000 -> error(mtls_no_request) end.
requests(Count) -> receive {mtls_request, _, _, _, _} -> requests(Count + 1) after 100 -> Count end.
