-module(http_gun_tls_test_server).
-export([start/0]).
start() ->
    application:ensure_all_started(ssl),
    {ok,L} = ssl:listen(0, [binary,{active,false},{reuseaddr,true},
        {certfile,"test/fixtures/localhost.crt"},{keyfile,"test/fixtures/localhost.key"}]),
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
