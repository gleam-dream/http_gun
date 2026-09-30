-module(http_gun_test_server).

-export([remove_fixture/1]).

-export([start/0,
         serve/1,
         persistent/0,
         observed/0,
         next_observed/0,
         temp_path/0,
         controlled/0,
         gated/0,
         await_request/1,
         send_control/2,
         await_closed/1,
         disconnect/1]).

start() -> serve(<<"HTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\n", 0, 255, 128>>).

serve(Response) ->
    {ok, L} = gen_tcp:listen(0,
                             [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(L),
    spawn(fun () ->
                  {ok, S} = gen_tcp:accept(L, 5000),
                  {ok, _} = gen_tcp:recv(S, 0, 5000),
                  ok = gen_tcp:send(S, Response),
                  gen_tcp:close(S),
                  gen_tcp:close(L)
          end),
    Port.

persistent() -> persistent(undefined).
observed() -> persistent(self()).
next_observed() ->
    receive {observed_request, Path} -> Path after 2000 -> error(no_observed_request) end.
persistent(Observer) ->
    {ok, L} = gen_tcp:listen(0,
                             [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(L),
    spawn(fun () -> accept_loop(L, Observer) end),
    Port.

accept_loop(L, Observer) ->
    case gen_tcp:accept(L, 5000) of
        {ok, S} ->
            spawn(fun () -> request_loop(S, <<>>, Observer) end),
            accept_loop(L, Observer);
        _ -> gen_tcp:close(L)
    end.

request_loop(S, Buf, Observer) ->
    case binary:match(Buf, <<"\r\n\r\n">>) of
        {At, 4} ->
            <<Head:At/binary, _:4/binary, Rest/binary>> = Buf,
            Len = content_length(binary:split(Head, <<"\r\n">>, [global])),
            {Body, Remaining} = read_body(S, Rest, Len),
            [First | _] = binary:split(Head, <<"\r\n">>),
            [Method, Path, _] = binary:split(First, <<" ">>, [global]),
            case Observer of undefined -> ok; _ -> Observer ! {observed_request, Path} end,
            Data = case Method of
                       <<"POST">> -> Body;
                       <<"HEAD">> -> <<>>;
                       _ -> <<"abc">>
                   end,
            ok = gen_tcp:send(S,
                              [<<"HTTP/1.1 200 OK\r\nContent-Length: ">>,
                               integer_to_binary(byte_size(Data)),
                               <<"\r\nX-Connection: ">>, list_to_binary(pid_to_list(self())),
                               <<"\r\n\r\n">>, Data]),
            request_loop(S, Remaining, Observer);
        nomatch ->
            case gen_tcp:recv(S, 0, 5000) of
                {ok, D} -> request_loop(S, <<Buf/binary, D/binary>>, Observer);
                _ -> gen_tcp:close(S)
            end
    end.

content_length([]) -> 0;
content_length([Line | Rest]) ->
    case binary:split(string:lowercase(Line), <<": ">>) of
        [<<"content-length">>, N] -> binary_to_integer(N);
        _ -> content_length(Rest)
    end.

read_body(_S, B, Len) when byte_size(B) >= Len ->
    <<Body:Len/binary, Rest/binary>> = B,
    {Body, Rest};
read_body(S, B, Len) ->
    {ok, D} = gen_tcp:recv(S, 0, 5000),
    read_body(S, <<B/binary, D/binary>>, Len).

temp_path() ->
    list_to_binary(filename:join("/tmp",
                                 "http-gun-" ++
                                     integer_to_list(erlang:unique_integer([positive, monotonic]))
                                         ++ "-" ++ os:getpid() ++ ".json")).

gated() -> controlled(false).

controlled() -> controlled(true).

controlled(Head) ->
    Parent = self(),
    {ok, L} = gen_tcp:listen(0,
                             [binary, {active, false}, {reuseaddr, true}, {ip, {127, 0, 0, 1}}]),
    {ok, {_, Port}} = inet:sockname(L),
    P = spawn(fun () ->
                      {ok, S} = gen_tcp:accept(L, 5000),
                      gen_tcp:close(L),
                      {ok, _} = gen_tcp:recv(S, 0, 5000),
                      Parent ! {request_received, self()},
                      case Head of
                          true ->
                              gen_tcp:send(S,
                                           <<"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n">>);
                          false -> ok
                      end,
                      control_loop(S)
              end),
    {Port, P}.

await_request(P) ->
    receive {request_received, P} -> ok after 2000 -> error(request_not_received) end.

control_loop(S) ->
    receive
        {send, From, Ref, B} ->
            R = gen_tcp:send(S, B),
            From ! {Ref, R},
            control_loop(S);
        {await_closed, From, Ref} ->
            R = gen_tcp:recv(S, 0, 2000),
            From ! {Ref, R},
            gen_tcp:close(S);
        disconnect -> gen_tcp:close(S)
        after 10000 -> gen_tcp:close(S)
    end.

send_control(P, B) ->
    Ref = make_ref(),
    P ! {send, self(), Ref, B},
    receive {Ref, ok} -> nil after 2000 -> error(server_timeout) end.

await_closed(P) ->
    Ref = make_ref(),
    P ! {await_closed, self(), Ref},
    receive
        {Ref, {error, closed}} -> true;
        {Ref, _} -> false
        after 3000 -> false
    end.

disconnect(P) ->
    P ! disconnect,
    nil.

remove_fixture(Path) ->
    file:delete(Path),
    nil.
