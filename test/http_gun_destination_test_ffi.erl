-module(http_gun_destination_test_ffi).
-export([listen/0, connected/1, counter/0, increment/1, count/1, sink/2, await_sink/1, stop_sink/1, mailbox_size/0, payload/1, echo_authority/1]).
listen() ->
    {ok, Socket} = gen_tcp:listen(0, [binary, {active, false}, {ip, {127,0,0,1}}]),
    {ok, {_, Port}} = inet:sockname(Socket),
    {Port, Socket}.
connected(Listener) ->
    Result = case gen_tcp:accept(Listener, 0) of
        {ok, Socket} -> gen_tcp:close(Socket), true;
        {error, timeout} -> false
    end,
    gen_tcp:close(Listener),
    Result.

counter() -> atomics:new(1, []).
increment(Counter) -> atomics:add_get(Counter, 1, 1).
count(Counter) -> atomics:get(Counter, 1).

sink(Tls, Warm) ->
    application:ensure_all_started(ssl),
    Transport = case Tls of true -> ssl; false -> gen_tcp end,
    Extra = case Tls of true -> [{certfile,"test/fixtures/ip.crt"},{keyfile,"test/fixtures/ip.key"}]; false -> [] end,
    {ok,L} = Transport:listen(0,[binary,{active,false},{reuseaddr,true},{recbuf,1024},{ip,{127,0,0,1}}|Extra]),
    {ok,{_,Port}} = case Tls of true -> ssl:sockname(L); false -> inet:sockname(L) end,
    Observer=self(),
    Pid=spawn(fun() ->
        {ok,S}=case Tls of
            true -> {ok,T}=ssl:transport_accept(L,3000), ssl:handshake(T,3000);
            false -> gen_tcp:accept(L,3000)
        end,
        Transport:close(L),
        case Warm of
            true -> {ok,_}=Transport:recv(S,0,3000),
                ok=Transport:send(S,<<"HTTP/1.1 204 No Content\r\n\r\n">>);
            false -> ok
        end,
        Observer ! {sink_ready,self()},
        receive stop -> Transport:close(S) after 10000 -> Transport:close(S) end
    end),
    {Port,Pid}.
await_sink(Pid) -> receive {sink_ready,Pid} -> nil after 3000 -> error(sink_not_ready) end.
stop_sink(Pid) ->
    Ref=monitor(process,Pid), Pid ! stop,
    receive {'DOWN',Ref,process,Pid,_} -> nil after 3000 -> error(sink_not_stopped) end.
mailbox_size() -> {message_queue_len,N}=process_info(self(),message_queue_len), N.
payload(Size) -> binary:copy(<<42>>,Size).

echo_authority(V6) ->
    Options=case V6 of true -> [inet6,{ip,{0,0,0,0,0,0,0,1}}]; false -> [{ip,{127,0,0,1}}] end,
    {ok,L}=gen_tcp:listen(0,[binary,{active,false}|Options]),
    {ok,{_,Port}}=inet:sockname(L),
    spawn(fun() ->
        {ok,S}=gen_tcp:accept(L,3000),
        {ok,Head}=gen_tcp:recv(S,0,3000),
        [Host]=[string:trim(V) || Line <- binary:split(Head,<<"\r\n">>,[global]),
            [K,V] <- [binary:split(Line,<<":">>)], string:lowercase(K)=:= <<"host">>],
        ok=gen_tcp:send(S,[<<"HTTP/1.1 200 OK\r\nContent-Length: ">>,integer_to_binary(byte_size(Host)),<<"\r\n\r\n">>,Host]),
        gen_tcp:close(S), gen_tcp:close(L)
    end),
    Port.
