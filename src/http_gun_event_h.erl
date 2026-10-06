%% Preserve terminal causes even when Gun exits before its owner monitors it.
%% Gun emits no gun_down for an initial connection failure with retries disabled.
-module(http_gun_event_h).
-behaviour(gun_event).
-export([
    init/2, domain_lookup_start/2, domain_lookup_end/2, connect_start/2,
    connect_end/2, tls_handshake_start/2, tls_handshake_end/2, request_start/2,
    request_headers/2, request_end/2, push_promise_start/2, push_promise_end/2,
    response_start/2, response_inform/2, response_headers/2, response_trailers/2,
    response_end/2, ws_upgrade/2, ws_recv_frame_start/2, ws_recv_frame_header/2,
    ws_recv_frame_end/2, ws_send_frame_start/2, ws_send_frame_end/2, protocol_changed/2,
    origin_changed/2, cancel/2, disconnect/2, terminate/2
]).

init(Event, Owner) -> gun_default_event_h:init(Event, Owner).
domain_lookup_start(Event, Owner) -> gun_default_event_h:domain_lookup_start(Event, Owner).
domain_lookup_end(Event, Owner) -> gun_default_event_h:domain_lookup_end(Event, Owner).
connect_start(Event, Owner) -> gun_default_event_h:connect_start(Event, Owner).
connect_end(Event, Owner) -> gun_default_event_h:connect_end(Event, Owner).
tls_handshake_start(Event, Owner) -> gun_default_event_h:tls_handshake_start(Event, Owner).
tls_handshake_end(Event, Owner) -> gun_default_event_h:tls_handshake_end(Event, Owner).
request_start(Event, Owner) -> gun_default_event_h:request_start(Event, Owner).
request_headers(Event, Owner) -> gun_default_event_h:request_headers(Event, Owner).
request_end(Event, Owner) -> gun_default_event_h:request_end(Event, Owner).
push_promise_start(Event, Owner) -> gun_default_event_h:push_promise_start(Event, Owner).
push_promise_end(Event, Owner) -> gun_default_event_h:push_promise_end(Event, Owner).
response_start(Event, Owner) -> gun_default_event_h:response_start(Event, Owner).
response_inform(Event, Owner) -> gun_default_event_h:response_inform(Event, Owner).
response_headers(Event, Owner) -> gun_default_event_h:response_headers(Event, Owner).
response_trailers(Event, Owner) -> gun_default_event_h:response_trailers(Event, Owner).
response_end(Event, Owner) -> gun_default_event_h:response_end(Event, Owner).
ws_upgrade(Event, Owner) -> gun_default_event_h:ws_upgrade(Event, Owner).
ws_recv_frame_start(Event, Owner) -> gun_default_event_h:ws_recv_frame_start(Event, Owner).
ws_recv_frame_header(Event, Owner) -> gun_default_event_h:ws_recv_frame_header(Event, Owner).
ws_recv_frame_end(Event, Owner) -> gun_default_event_h:ws_recv_frame_end(Event, Owner).
ws_send_frame_start(Event, Owner) -> gun_default_event_h:ws_send_frame_start(Event, Owner).
ws_send_frame_end(Event, Owner) -> gun_default_event_h:ws_send_frame_end(Event, Owner).
protocol_changed(Event, Owner) -> gun_default_event_h:protocol_changed(Event, Owner).
origin_changed(Event, Owner) -> gun_default_event_h:origin_changed(Event, Owner).
cancel(Event, Owner) -> gun_default_event_h:cancel(Event, Owner).
disconnect(Event, Owner) -> gun_default_event_h:disconnect(Event, Owner).
terminate(Event = #{reason := Reason}, Owner) ->
    Owner ! {gun_error, self(), Reason},
    gun_default_event_h:terminate(Event, Owner).
