-module(http_gun_reuse_test_server).
-export([start/2, close_peer/1, stop/1]).

%% A controlled TLS/H1 peer. Request bodies are not replayed: each response
%% exposes the connection number and the sequence number on that connection.
start(Tls, CloseHeader) ->
    application:ensure_all_started(ssl),
    Parent = self(),
    Pid = spawn(fun() ->
        Transport = case Tls of true -> ssl; false -> gen_tcp end,
        Extra = case Tls of true -> [{certfile,"test/fixtures/localhost.crt"},{keyfile,"test/fixtures/localhost.key"}]; false -> [] end,
        {ok,L} = Transport:listen(0,[binary,{active,false},{reuseaddr,true},{ip,{127,0,0,1}}|Extra]),
        {ok,{_,Port}} = case Tls of true -> ssl:sockname(L); false -> inet:sockname(L) end,
        Parent ! {self(),port,Port},
        accept(L,Transport,CloseHeader,1)
    end),
    receive {Pid,port,Port} -> {Port,Pid} after 3000 -> error(listen_timeout) end.

accept(L,T,Close,N) ->
    {ok,S} = case T of ssl -> {ok,Raw}=ssl:transport_accept(L,3000), ssl:handshake(Raw,3000); gen_tcp -> gen_tcp:accept(L,3000) end,
    case serve(S,T,Close,N,1,<<>>) of
        next -> accept(L,T,Close,N+1);
        stop -> T:close(L)
    end.

serve(S,T,Close,N,Sequence,Buffer) ->
    case binary:split(Buffer,<<"\r\n\r\n">>) of
        [_,Rest] ->
            Header=case Close of true -> <<"Connection: close\r\n">>; false -> <<>> end,
            ok=T:send(S,[<<"HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Connection: ">>,integer_to_binary(N),
                         <<"\r\nX-Sequence: ">>,integer_to_binary(Sequence),<<"\r\n">>,Header,<<"\r\nok">>]),
            serve(S,T,Close,N,Sequence+1,Rest);
        _ ->
            receive
                {close,From,Ref} -> T:close(S), From!{Ref,closed}, next;
                stop -> T:close(S), stop
            after 0 ->
                case T:recv(S,0,10) of
                    {ok,Bytes} -> serve(S,T,Close,N,Sequence,<<Buffer/binary,Bytes/binary>>);
                    {error,timeout} -> serve(S,T,Close,N,Sequence,Buffer);
                    {error,closed} -> next
                end
            end
    end.
close_peer(Pid) ->
    Ref=make_ref(), Pid!{close,self(),Ref},
    receive {Ref,closed} -> nil after 3000 -> error(close_timeout) end.
stop(Pid) -> exit(Pid,kill), nil.
