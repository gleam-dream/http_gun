%% Test-only measurements and finite load source. Never linked into the package.
-module(http_gun_measure_ffi).
-export([now/0, sampler/0, finish/1, large/1, pause/1, reductions/0]).
reductions() -> {N,_} = erlang:statistics(reductions), N.
now() -> erlang:monotonic_time(microsecond).
pause(Ms) -> receive after Ms -> nil end.
sampler() -> spawn_link(fun() -> sample({0,0,0,0,0}) end).
finish(P) -> P ! {finish,self()}, receive {sampled,P,Stats} -> Stats after 3000 -> error(sampler_timeout) end.
sample({Mem,Total,Max,Count,Ports}) ->
    Q = [N || P <- processes(), {message_queue_len,N} <- [process_info(P,message_queue_len)]],
    Stats = {max(Mem,erlang:memory(total)),max(Total,lists:sum(Q)),max(Max,lists:max([0|Q])),
        max(Count,length(Q)),max(Ports,length(erlang:ports()))},
    receive {finish,From} -> From ! {sampled,self(),Stats}
    after 10 -> sample(Stats) end.
large(Bytes) ->
    {ok,L} = gen_tcp:listen(0,[binary,{active,false},{reuseaddr,true},{ip,{127,0,0,1}}]),
    {ok,{_,Port}} = inet:sockname(L),
    spawn(fun() ->
        {ok,S} = gen_tcp:accept(L,5000), gen_tcp:close(L),
        {ok,_} = gen_tcp:recv(S,0,5000),
        ok = gen_tcp:send(S,[<<"HTTP/1.1 200 OK\r\nContent-Length: ">>,integer_to_binary(Bytes),<<"\r\n\r\n">>]),
        send(S,Bytes), gen_tcp:close(S)
    end), Port.
send(_,0) -> ok;
send(S,N) -> Size=min(8192,N), case gen_tcp:send(S,binary:copy(<<42>>,Size)) of ok -> send(S,N-Size); _ -> ok end.
