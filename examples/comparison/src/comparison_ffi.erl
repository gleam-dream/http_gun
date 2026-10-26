%% Comparison-only entry point and finite two-response server.
-module(comparison_ffi).
-export([arguments/0, sequence/0, mixed/0]).
%% Clients have a 60-second request deadline. The fixture must outlive it.
-define(PEER_IDLE_TIMEOUT, 65000).
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
    {Port, _Acceptor} = mixed(?PEER_IDLE_TIMEOUT),
    Port.
mixed(IdleTimeout) ->
    {ok,L}=gen_tcp:listen(0,[binary,{active,false},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}}=inet:sockname(L),
    Acceptor = spawn(fun() ->
        {ok,S}=gen_tcp:accept(L,5000),
        owned_peer(S, fun(Socket) ->
            read_head(Socket,<<>>),
            gen_tcp:send(Socket,<<"HTTP/1.1 200 OK\r\nContent-Length: 33554432\r\nConnection: close\r\n\r\n">>),
            send_bytes(Socket,33554432),gen_tcp:close(Socket)
        end),
        accept_fast(L,IdleTimeout)
    end),{Port, Acceptor}.
accept_fast(L,IdleTimeout) ->
    case gen_tcp:accept(L,IdleTimeout) of
        {ok,S} -> owned_peer(S,fun fast/1),accept_fast(L,IdleTimeout);
        _ -> gen_tcp:close(L)
    end.
owned_peer(Socket, Serve) ->
    Worker = spawn(fun() -> receive owned -> Serve(Socket) end end),
    ok = gen_tcp:controlling_process(Socket, Worker),
    Worker ! owned,
    ok.
read_head(S,B) ->
    case binary:match(B,<<"\r\n\r\n">>) of
        nomatch -> case gen_tcp:recv(S,0,?PEER_IDLE_TIMEOUT) of {ok,D}->read_head(S,<<B/binary,D/binary>>); _->closed end;
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

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").

accepted_peer_survives_listener_shutdown_test() ->
    {Port, Acceptor} = mixed(100),
    Monitor = erlang:monitor(process, Acceptor),
    Options = [binary, {active, false}],
    Request = <<"GET / HTTP/1.1\r\nHost: localhost\r\n\r\n">>,
    {ok, Slow} = gen_tcp:connect({127,0,0,1}, Port, Options, 1000),
    {ok, Fast} = gen_tcp:connect({127,0,0,1}, Port, Options, 1000),
    try
        ok = gen_tcp:send(Slow, Request),
        ok = gen_tcp:send(Fast, Request),
        read_response(Fast, <<>>),
        receive
            {'DOWN', Monitor, process, Acceptor, normal} -> ok
        after 2000 -> error(listener_did_not_stop)
        end,
        ok = gen_tcp:send(Fast, Request),
        read_response(Fast, <<>>)
    after
        gen_tcp:close(Fast),
        gen_tcp:close(Slow)
    end.

read_response(Socket, Buffer) ->
    case binary:match(Buffer, <<"\r\n\r\nabc">>) of
        nomatch ->
            {ok, Data} = gen_tcp:recv(Socket, 0, 1000),
            read_response(Socket, <<Buffer/binary,Data/binary>>);
        _ -> ok
    end.
-endif.
