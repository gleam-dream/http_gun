-module(http_gun_parser_probe).
-export([main/0]).
main() ->
  {ok,_}=application:ensure_all_started(gun),
  lists:foreach(fun({Name,Bytes}) ->
    Port=http_gun_test_server:serve(Bytes),
    {ok,P}=gun:open({127,0,0,1},Port,#{retry=>0}),
    {ok,http}=gun:await_up(P,1000),
    R=gun:get(P,<<"/">>),
    A=gun:await(P,R,1000),
    B=case A of {response,nofin,_,_} -> gun:await_body(P,R,1000); _ -> none end,
    io:format("~p: ~p / ~p~n",[Name,A,B]),
    gun:close(P)
  end,[
    {control_status,<<"HTTP/1.1 200 O",1,"K\r\nContent-Length: 0\r\n\r\n">>},
    {control_header,<<"HTTP/1.1 200 OK\r\nContent-Length: 0\r\nX-Test: a",1,"b\r\n\r\n">>},
    {bare_lf,<<"HTTP/1.1 200 OK\nContent-Length: 0\n\n">>},
    {signed_length,<<"HTTP/1.1 200 OK\r\nContent-Length: +1\r\n\r\nx">>},
    {signed_chunk,<<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n+1\r\nx\r\n0\r\n\r\n">>}
  ]), halt().
