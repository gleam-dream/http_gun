-module(http_gun_h2_server).

-export([start/0, controlled/0]).

start() -> start(none).

controlled() -> start(self()).

start(Observer) ->
    application:ensure_all_started(ssl),
    {ok, L} = ssl:listen(0,
                         [binary,
                          {active, false},
                          {reuseaddr, true},
                          {ip, {127, 0, 0, 1}},
                          {certfile, "test/fixtures/localhost.crt"},
                          {keyfile, "test/fixtures/localhost.key"},
                          {alpn_preferred_protocols, [<<"h2">>]}]),
    {ok, {_, Port}} = ssl:sockname(L),
    spawn(fun () -> accept(L, Observer) end),
    Port.

accept(L, Observer) ->
    case ssl:transport_accept(L, 5000) of
        {ok, S} ->
            case ssl:handshake(S, 5000) of
                {ok, S} ->
                    P = spawn(fun () ->
                                      receive
                                          go ->
                                              {ok, <<"PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n">>} =
                                                  ssl:recv(S, 24, 5000),
                                              ok = ssl:send(S,
                                                            cow_http2:settings(#{max_concurrent_streams
                                                                                     => 1000})),
                                              loop(S,
                                                   <<>>,
                                                   cow_hpack:init(),
                                                   cow_hpack:init(),
                                                   erlang:unique_integer([positive]),
                                                   Observer)
                                      end
                              end),
                    ok = ssl:controlling_process(S, P),
                    P ! go,
                    accept(L, Observer);
                {error, _} ->
                    ssl:close(S),
                    accept(L, Observer)
            end;
        _ -> ssl:close(L)
    end.

loop(S, B, Decode, Encode, Id, Observer) -> loop(S, B, Decode, Encode, Id, Observer, #{}).

loop(S, B, Decode, Encode, Id, Observer, Pending) ->
    case cow_http2:parse(B) of
        more ->
            case ssl:recv(S, 0, 10000) of
                {ok, D} -> loop(S, <<B/binary, D/binary>>, Decode, Encode, Id, Observer, Pending);
                _ -> ssl:close(S)
            end;
        {ok, {settings, _}, Rest} ->
            ssl:send(S, cow_http2:settings_ack()),
            loop(S, Rest, Decode, Encode, Id, Observer, Pending);
        {ok, {headers, Stream, _, head_fin, Block}, Rest} ->
            {H, D1} = cow_hpack:decode(Block, Decode),
            Path = proplists:get_value(<<":path">>, H),
            ExtraHeaders = case Path of
                <<"/many-headers">> -> lists:duplicate(110, {<<"x-many">>, <<"a">>});
                _ -> []
            end,
            {HB, E1} = cow_hpack:encode([{<<":status">>, <<"200">>},
                                         {<<"x-connection">>, integer_to_binary(Id)},
                                         {<<"x-stream">>, integer_to_binary(Stream)} | ExtraHeaders],
                                        Encode),
            ssl:send(S, cow_http2:headers(Stream, nofin, HB)),
            Pending1 = case Path of
                           <<"/window-demand">> ->
                               DataBlock = binary:copy(<<42>>, 8192),
                               ok = ssl:send(S,
                                             [cow_http2:data(Stream, nofin, DataBlock),
                                              cow_http2:data(Stream, nofin, DataBlock)]),
                               Observer ! {h2_waiting_window, self(), Stream},
                               Pending#{Stream => true};
                           _ ->
                               case Path of
                                   <<"/capture-count">> ->
                                       Observer ! {h2_stream_ready, self(), Stream},
                                       receive
                                           {data_frames, From, Ref, Count} ->
                                               ok = ssl:send(S,
                                                             [cow_http2:data(Stream, nofin, <<42>>)
                                                              || _ <- lists:seq(1, Count)]),
                                               From ! {Ref, sent}
                                           after 2000 -> error(data_frames_not_requested)
                                       end;
                                   <<"/slow">> ->
                                       ssl:send(S, cow_http2:data(Stream, nofin, <<"first">>));
                                   <<"/reset">> ->
                                       ssl:send(S, cow_http2:rst_stream(Stream, cancel));
                                   <<"/capacity-zero">> ->
                                       ssl:send(S,
                                                [cow_http2:settings(#{max_concurrent_streams => 0}),
                                                 cow_http2:data(Stream, fin, <<"done">>)]);
                                   <<"/goaway">> ->
                                       ssl:send(S,
                                                [cow_http2:goaway(Stream, no_error, <<>>),
                                                 cow_http2:data(Stream, fin, <<"done">>)]);
                                   <<"/loss">> -> ssl:close(S);
                                   _ -> ssl:send(S, cow_http2:data(Stream, fin, <<0, 255, 128>>))
                               end,
                               Pending
                       end,
            loop(S, Rest, D1, E1, Id, Observer, Pending1);
        {ok, {window_update, Stream, _}, Rest} when is_map_key(Stream, Pending) ->
            ok = ssl:send(S, cow_http2:data(Stream, fin, <<"end">>)),
            Observer ! {h2_window_resumed, self(), Stream},
            loop(S, Rest, Decode, Encode, Id, Observer, maps:remove(Stream, Pending));
        {ok, {ping, V}, Rest} ->
            ssl:send(S, cow_http2:ping_ack(V)),
            loop(S, Rest, Decode, Encode, Id, Observer, Pending);
        {ok, _, Rest} -> loop(S, Rest, Decode, Encode, Id, Observer, Pending);
        _ -> ssl:close(S)
    end.
