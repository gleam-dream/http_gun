-module(http_gun_owner_fault_test_ffi).
-export([monitored_by/1]).

%% Fault injection only: the processes that monitor Pid.
monitored_by(Pid) ->
    case erlang:process_info(Pid, monitored_by) of
        {monitored_by, Monitors} -> [M || M <- Monitors, is_pid(M)];
        undefined -> []
    end.
