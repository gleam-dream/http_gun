-module(http_gun_telemetry_test_ffi).
-export([attach_native/2, detach_native/1, forward/4]).

%% Attaches a plain :telemetry handler, as an Erlang or Elixir application
%% would, and forwards each lifecycle event's native metadata map to Subject.
attach_native(Id, Subject) ->
    ok = telemetry:attach(Id, [http_gun, lifecycle], fun ?MODULE:forward/4, Subject),
    nil.

detach_native(Id) ->
    _ = telemetry:detach(Id),
    nil.

forward(_Event, _Measurements, Metadata, Subject) ->
    gleam@erlang@process:send(Subject, Metadata).
