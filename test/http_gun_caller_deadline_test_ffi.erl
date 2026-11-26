-module(http_gun_caller_deadline_test_ffi).
-export([suspend/1, resume/1, queued/1, handled/1]).

%% Fault injection only: hold a process alive without letting it handle
%% messages, then let it continue.
suspend(Pid) -> sys:suspend(Pid), nil.
resume(Pid) -> sys:resume(Pid), nil.

%% How many messages wait in Pid's mailbox.
queued(Pid) ->
    {message_queue_len, Count} = erlang:process_info(Pid, message_queue_len),
    Count.

%% Return once Pid has handled every message that arrived before this call:
%% a process handles its mailbox in order, so it answers this system request
%% only after the messages ahead of it.
handled(Pid) -> _ = sys:get_state(Pid, 2000), nil.
