%% Drives http_gun_event_h directly with the state a signer identity opens a
%% connection with, and returns the reason the handler reports at
%% termination. No pool, ssl or signer runs, and none can reach this branch
%% through the public API: the pool ignores the cause of a connection that
%% already came up.
-module(http_gun_event_handler_test_ffi).
-export([terminated_after_handshake/2]).

terminated_after_handshake(HandshakeSucceeded, Refused) ->
    Flag = atomics:new(1, []),
    State0 = {self(), Flag},
    End = case HandshakeSucceeded of
        true -> #{socket => undefined, protocol => http};
        false -> #{error => {tls_alert, {handshake_failure, "probe"}}}
    end,
    case HandshakeSucceeded of
        true -> ok;
        false -> Refused andalso atomics:put(Flag, 1, 1)
    end,
    State1 = http_gun_event_h:tls_handshake_end(End, State0),
    %% A refusal after a successful opening handshake comes from a TLS 1.2
    %% renegotiation, which sets the same flag.
    HandshakeSucceeded andalso Refused andalso atomics:put(Flag, 1, 1),
    _ = http_gun_event_h:terminate(#{reason => closed}, State1),
    receive {gun_error, Self, Reason} when Self =:= self() -> Reason
    after 1000 -> no_report end.
