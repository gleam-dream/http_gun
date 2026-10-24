%% Comparison-only entry point and finite two-response server.
-module(comparison_ffi).
-export([arguments/0, sequence/0, mixed/0]).
arguments() -> [list_to_binary(A) || A <- init:get_plain_arguments()].
sequence() ->
    {ok,L}=gen_tcp:listen(0,[binary,{active,false},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),
    spawn(fun() -> lists:foreach(fun(B) ->
        {ok,S}=gen_tcp:accept(L,5000), {ok,_}=gen_tcp:recv(S,0,5000),
        ok=gen_tcp:send(S,[<<"HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\n">>,B]),
        gen_tcp:close(S)
    end,[<<"abc">>,<<"xyz">>]),gen_tcp:close(L) end),Port.

%% One slow connection and ordinary keep-alive siblings on the same origin.
mixed() ->
    {ok,L}=gen_tcp:listen(0,[binary,{active,false},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),
    spawn(fun() ->
        {ok,S}=gen_tcp:accept(L,5000),
        spawn(fun() ->
            read_head(S,<<>>),
            gen_tcp:send(S,<<"HTTP/1.1 200 OK\r\nContent-Length: 33554432\r\nConnection: close\r\n\r\n">>),
            send_bytes(S,33554432),gen_tcp:close(S)
        end),
        accept_fast(L)
    end),Port.
accept_fast(L) ->
    case gen_tcp:accept(L,5000) of
        {ok,S} -> spawn(fun() -> fast(S) end),accept_fast(L);
        _ -> gen_tcp:close(L)
    end.
read_head(S,B) ->
    case binary:match(B,<<"\r\n\r\n">>) of
        nomatch -> case gen_tcp:recv(S,0,5000) of {ok,D}->read_head(S,<<B/binary,D/binary>>); _->closed end;
        _ -> ok
    end.
fast(S) ->
    case read_head(S,<<>>) of
        ok -> gen_tcp:send(S,[<<"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nX-Connection: ">>,
            list_to_binary(pid_to_list(self())),<<"\r\n\r\nabc">>]),fast(S);
        closed -> gen_tcp:close(S)
    end.
send_bytes(_,0) -> ok;
send_bytes(S,N) ->
    Size=min(N,8192),
    case gen_tcp:send(S,binary:copy(<<42>>,Size)) of ok -> send_bytes(S,N-Size); _->ok end.
