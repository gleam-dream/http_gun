-module(http_gun_tls_test_server).
-export([start/0, ip/0, anchors/1, tls12_cbc_only/0, slow_handshake/2]).
anchors(Name) ->
    {ok, Pem} = file:read_file("test/fixtures/" ++ binary_to_list(Name) ++ ".crt"),
    [Der || {'Certificate', Der, not_encrypted} <- public_key:pem_decode(Pem)].
start() -> start("localhost").
%% A server that accepts only TLS 1.2 ECDHE-RSA-AES256-SHA384, a CBC suite
%% that OTP no longer offers by default, as some government services do.
tls12_cbc_only() ->
    start("localhost", [{versions, ['tlsv1.2']},
        {ciphers, [ssl:str_to_suite("ECDHE-RSA-AES256-SHA384")]}]).
ip() -> start("ip").
start(Name) -> start(Name, []).
start(Name, Extra) ->
    application:ensure_all_started(ssl),
    {ok,L} = ssl:listen(0, [binary,{active,false},{reuseaddr,true},
        {certfile,"test/fixtures/" ++ Name ++ ".crt"},{keyfile,"test/fixtures/" ++ Name ++ ".key"} | Extra]),
    {ok,{_,Port}} = ssl:sockname(L),
    spawn(fun() ->
        case ssl:transport_accept(L,3000) of
            {ok,T} -> case ssl:handshake(T,3000) of
                {ok,S} -> case ssl:recv(S,0,3000) of
                    {ok,_} -> ssl:send(S,<<"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc">>);
                    _ -> ok end, ssl:close(S);
                _ -> ok end;
            _ -> ok end,
        ssl:close(L)
    end),
    Port.

%% A keep-alive server that waits Delay ms before each TLS handshake, so each
%% new connection costs a known preparation time, and Work ms before each
%% response, so a connection stays busy while it serves one request. It
%% serves "abc" until the client closes. Used by the cold-start benchmark.
slow_handshake(Delay, Work) ->
    application:ensure_all_started(ssl),
    {ok,L} = ssl:listen(0, [binary,{active,false},{reuseaddr,true},{backlog,128},
        {certfile,"test/fixtures/localhost.crt"},{keyfile,"test/fixtures/localhost.key"}]),
    {ok,{_,Port}} = ssl:sockname(L),
    spawn(fun() -> slow_accept(L, Delay, Work) end),
    Port.
slow_accept(L, Delay, Work) ->
    case ssl:transport_accept(L, 30000) of
        {ok,T} ->
            spawn(fun() ->
                timer:sleep(Delay),
                case ssl:handshake(T, 5000) of
                    {ok,S} -> slow_serve(S, Work);
                    _ -> ok
                end
            end),
            slow_accept(L, Delay, Work);
        _ -> ssl:close(L)
    end.
slow_serve(S, Work) ->
    case ssl:recv(S, 0, 30000) of
        {ok,_} ->
            timer:sleep(Work),
            ssl:send(S, <<"HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\nabc">>),
            slow_serve(S, Work);
        _ -> ssl:close(S)
    end.
