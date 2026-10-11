#!/usr/bin/env escript
%% Qualification probe of Cowlib's public encoder, not an HTTP Gun cookie API.
main([Source]) ->
    {ok, cow_cookie, Bytes} = compile:file(filename:join([Source, "src", "cow_cookie.erl"]),
        [binary, {i, filename:join(Source, "include")}, return_errors]),
    {module, cow_cookie} = code:load_binary(cow_cookie, "qualified-source", Bytes),
    <<"session=abc123; empty=">> = iolist_to_binary(cow_cookie:cookie(
        [{<<"session">>, <<"abc123">>}, {<<"empty">>, <<>>}])),
    <<"session=abc123">> = iolist_to_binary(cow_cookie:cookie(
        [{[<<"ses">>, "sion"], [<<"abc">>, "123"]}])),
    Inputs = [{name, [{Value, <<"ok">>}]} || Value <-
        [<<"session;admin">>, <<"session=admin">>, <<"session\r\nx-injected">>]]
        ++ [{value, [{<<"session">>, Value}]} || Value <-
        [<<"abc; admin=1">>, <<"abc\r\nx-injected: yes">>, <<"abc\n">>]],
    Failures = lists:filtermap(fun({Kind, Cookies}) ->
        try iolist_to_binary(cow_cookie:cookie(Cookies)) of
            _ -> {true, Kind}
        catch error:badarg -> false end
    end, Inputs),
    io:format("Valid binary and iodata controls passed; rejected ~p/~p injection inputs.~n",
        [length(Inputs) - length(Failures), length(Inputs)]),
    case Failures of [] -> halt(0); _ -> halt(1) end.
