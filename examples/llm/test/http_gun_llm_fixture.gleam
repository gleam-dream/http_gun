//// Provider fixtures adapted from the reviewed LLM Wire fragmentation tests.
//// Revision/hashes: docs/evidence/wave11/donor-source.json; Apache-2.0.

pub fn openai() -> String {
  "event: response.output_item.added\r\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\r\n\r\nevent: response.output_text.delta\r\ndata: {\"output_index\":0,\"item_id\":\"item\",\"delta\":\"hé🙂\"}\r\n\r\nevent: response.output_item.done\r\ndata: {\"output_index\":0,\"item\":{\"id\":\"item\",\"type\":\"message\"}}\r\n\r\nevent: response.completed\r\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\r\n\r\n"
}

pub fn anthropic() -> String {
  "event: message_start\r\ndata: {\"type\":\"message_start\",\"message\":{\"id\":\"m1\",\"type\":\"message\",\"role\":\"assistant\",\"model\":\"claude\",\"usage\":{\"input_tokens\":1,\"output_tokens\":1}}}\r\n\r\nevent: content_block_start\r\ndata: {\"type\":\"content_block_start\",\"index\":0,\"content_block\":{\"type\":\"text\",\"text\":\"\"}}\r\n\r\nevent: content_block_delta\r\ndata: {\"type\":\"content_block_delta\",\"index\":0,\"delta\":{\"type\":\"text_delta\",\"text\":\"hé🙂\"}}\r\n\r\nevent: content_block_stop\r\ndata: {\"type\":\"content_block_stop\",\"index\":0}\r\n\r\nevent: message_delta\r\ndata: {\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"},\"usage\":{\"output_tokens\":1}}\r\n\r\nevent: message_stop\r\ndata: {\"type\":\"message_stop\"}\r\n\r\n"
}

pub fn google() -> String {
  "data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hé🙂\"}]}}]}\r\n\r\ndata: {\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"parts\":[]}}]}\r\n\r\n"
}
