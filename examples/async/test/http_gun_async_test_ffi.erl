%% Test-only mailbox observation; no process orchestration.
-module(http_gun_async_test_ffi).
-export([mailbox_size/0]).
mailbox_size() -> {message_queue_len, N} = process_info(self(), message_queue_len), N.
