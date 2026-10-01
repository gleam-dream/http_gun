import gleam/bit_array
import gleam/erlang/process
import gleam/http/response
import gleam/int
import gleam/io
import gleam/list
import gleam/option
import gleam/string
import http_gun
import http_gun/cassette
import http_gun/config as http_config
import http_gun/destination
import http_gun/error as http_error
import http_gun/fixture
import http_gun/recording
import http_gun/testing
import http_gun_llm_consumer as consumer
import http_gun_llm_fixture as fixtures
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/anthropic
import llm_wire/provider/google
import llm_wire/provider/openai
import llm_wire/types

@external(erlang, "http_gun_test_server", "controlled")
fn server() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "send_control")
fn emit(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_test_server", "await_request")
fn requested(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

pub fn main() -> Nil {
  terminal_before_eof()
  progress_before_eof_and_cancellation()
  every_split_through_public_stream()
  live_record_replay_terminal_without_eof()
  bounded_errors_and_status_policy()
  disconnect_preserves_evidence()
  idle_wait_closes_stream()
  io.println(
    "LLM streaming: live progress, cancellation, provider terminal, fragmentation and real record/replay passed.",
  )
}

fn terminal_before_eof() -> Nil {
  let #(port, server) = server()
  let assert Ok(endpoint) =
    types.endpoint("http://localhost:" <> int.to_string(port))
  let assert Ok(key) = types.api_key("local-test-key")
  let settings =
    config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
  let assert Ok(model) = types.model_id("fixture-model")
  let assert Ok(client) = http_gun.start(http_local_config())
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(done, consumer.text(client, settings, model, "Hello"))
    })
  requested(server)
  let events =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"message\"}}\n\nevent: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"Hello\"}\n\nevent: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"message\"}}\n\nevent: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let assert Ok(size) = int.to_base_string(string.byte_size(events), 16)
  emit(server, <<size:utf8, "\r\n":utf8, events:utf8, "\r\n":utf8>>)
  // The server intentionally never sends HTTP EOF.
  let assert Ok(Ok(provider.Text("Hello", _))) = process.receive(done, 1000)
  let assert True = closed(server)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn settings(port: Int) -> config.Config {
  let assert Ok(endpoint) =
    types.endpoint("http://localhost:" <> int.to_string(port))
  let assert Ok(key) = types.api_key("local-test-key")
  config.openai(openai.options(key)) |> config.with_endpoint(endpoint)
}

fn model() -> types.ModelId {
  let assert Ok(model) = types.model_id("fixture-model")
  model
}

fn chunk(server: process.Pid, text: String) -> Nil {
  let assert Ok(size) = int.to_base_string(string.byte_size(text), 16)
  emit(server, <<size:utf8, "\r\n":utf8, text:utf8, "\r\n":utf8>>)
}

fn progress_before_eof_and_cancellation() -> Nil {
  let #(port, server) = server()
  let settings = settings(port)
  let assert Ok(client) = http_gun.start(http_local_config())
  let progress = process.new_subject()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        consumer.stream(client, settings, model(), "Hello", fn(item) {
          case item {
            types.TextDelta(_, text) -> {
              process.send(progress, text)
              consumer.Stop
            }
            _ -> consumer.Continue
          }
        }),
      )
    })
  requested(server)
  let assert Ok(#(prefix, _)) =
    string.split_once(fixtures.openai(), "event: response.output_item.done")
  chunk(server, prefix)
  let assert Ok("hé🙂") = process.receive(progress, 1000)
  let assert Ok(Error(consumer.Cancelled(retry))) = process.receive(done, 1000)
  let assert True =
    retry.response_bytes_observed && retry.semantic_progress_observed
  let assert True = closed(server)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn every_split_through_public_stream() -> Nil {
  let assert Ok(key) = types.api_key("offline-key")
  let scenarios = [
    #(config.openai(openai.options(key)), fixtures.openai()),
    #(config.anthropic(anthropic.options(key)), fixtures.anthropic()),
    #(config.google(google.options(key)), fixtures.google()),
  ]
  list.each(scenarios, fn(pair) {
    let #(settings, raw) = pair
    let bytes = bit_array.from_string(raw)
    let size = bit_array.byte_size(bytes)
    let assert Ok(req) = consumer.prepare(settings, model(), "Hello")
    let exchanges =
      list.map(int.range(0, size + 1, [], fn(acc, at) { [at, ..acc] }), fn(at) {
        let assert Ok(first) = bit_array.slice(bytes, 0, at)
        let assert Ok(last) = bit_array.slice(bytes, at, size - at)
        fixture.Exchange(
          req,
          fixture.Respond(
            response.Response(200, [], [first, last]),
            fixture.Complete([]),
          ),
        )
      })
    let assert Ok(client) = testing.start(http_local_config(), exchanges)
    list.each(exchanges, fn(_) {
      let assert Ok(provider.Text("hé🙂", _)) =
        consumer.text(client, settings, model(), "Hello")
    })
    let assert Ok(Nil) = http_gun.stop(client)
    io.println(
      "Provider stream split points checked: " <> int.to_string(size + 1),
    )
  })
}

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

@external(erlang, "http_gun_test_server", "remove_fixture")
fn remove(path: String) -> Nil

fn finish(
  recording: recording.Recording,
  attempts: Int,
) -> Result(String, recording.FinishError) {
  case cassette.finish(recording) {
    Error(recording.Busy) if attempts > 0 -> finish(recording, attempts - 1)
    result -> result
  }
}

fn live_record_replay_terminal_without_eof() -> Nil {
  let #(port, server) = server()
  let settings = settings(port)
  let path = temp_path()
  let assert Ok(recorded) =
    cassette.record(http_local_config(), path, recording.default())
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        consumer.text(recorded.client, settings, model(), "Hello"),
      )
    })
  requested(server)
  chunk(server, fixtures.openai())
  let assert Ok(Ok(provider.Text("hé🙂", _))) = process.receive(done, 2000)
  let assert True = closed(server)
  let assert Ok(_) = finish(recorded.recording, 1000)
  let assert Ok(Nil) = http_gun.stop(recorded.client)
  let assert Ok(tape) = cassette.load(path, 100_000)
  let assert Ok(playback) = cassette.playback(tape, http_local_config())
  let assert Ok(provider.Text("hé🙂", _)) =
    consumer.text(playback, settings, model(), "Hello")
  let assert Ok(Nil) = http_gun.stop(playback)
  remove(path)
}

fn scripted_error(
  settings: config.Config,
  status: Int,
  headers: List(#(String, String)),
  chunks: List(BitArray),
) -> consumer.Error {
  let assert Ok(req) = consumer.prepare(settings, model(), "Hello")
  let assert Ok(client) =
    testing.start(http_local_config(), [
      fixture.Exchange(
        req,
        fixture.Respond(
          response.Response(status, headers, chunks),
          fixture.Complete([]),
        ),
      ),
    ])
  let assert Error(error) = consumer.text(client, settings, model(), "Hello")
  let assert Ok(Nil) = http_gun.stop(client)
  error
}

fn bounded_errors_and_status_policy() -> Nil {
  let settings = settings(1)
  let assert consumer.Status(429, option.Some("7")) =
    scripted_error(settings, 429, [#("retry-after", "7")], [<<"failure":utf8>>])
  let assert consumer.Compressed("gzip") =
    scripted_error(settings, 200, [#("content-encoding", "gzip")], [<<0, 255>>])
  let assert consumer.Incomplete =
    scripted_error(settings, 200, [], [<<"data: incomplete":utf8>>])
  let limits = config.limits(settings)
  let limited =
    config.with_limits(
      settings,
      types.Limits(..limits, response_body_bytes_limit: 8),
    )
  let assert consumer.Provider(types.ResourceLimitExceeded(
    "response_body_bytes_limit",
    8,
    _,
  )) = scripted_error(limited, 200, [], [<<"data: too much":utf8>>])
  let limited =
    config.with_limits(settings, types.Limits(..limits, line_bytes_limit: 8))
  let assert consumer.Provider(types.ResourceLimitExceeded(
    "line_bytes_limit",
    8,
    _,
  )) = scripted_error(limited, 200, [], [<<"data: too long":utf8>>])
  Nil
}

@external(erlang, "http_gun_test_server", "disconnect")
fn disconnect(server: process.Pid) -> Nil

fn disconnect_preserves_evidence() -> Nil {
  let #(port, server) = server()
  let settings = settings(port)
  let assert Ok(client) = http_gun.start(http_local_config())
  let progress = process.new_subject()
  let done = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      process.send(
        done,
        consumer.stream(client, settings, model(), "Hello", fn(item) {
          case item {
            types.TextDelta(_, _) -> process.send(progress, Nil)
            _ -> Nil
          }
          consumer.Continue
        }),
      )
    })
  requested(server)
  let assert Ok(#(prefix, _)) =
    string.split_once(fixtures.openai(), "event: response.output_item.done")
  chunk(server, prefix)
  let assert Ok(Nil) = process.receive(progress, 1000)
  disconnect(server)
  let assert Ok(Error(consumer.Http(_, retry))) = process.receive(done, 1000)
  let assert True =
    retry.response_bytes_observed && retry.semantic_progress_observed
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

fn idle_wait_closes_stream() -> Nil {
  let #(port, server) = server()
  let defaults = settings(port)
  let settings = config.with_deadlines(defaults, types.Deadlines(2000, 50, 25))
  let assert Ok(client) = http_gun.start(http_local_config())
  let assert Error(consumer.Http(
    http_error.Failure(http_error.ReadTimeout, _),
    retry,
  )) = consumer.text(client, settings, model(), "Hello")
  let assert False = retry.response_bytes_observed
  let assert True = closed(server)
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}

// These exercises connect only to explicitly permitted local test servers.
fn http_local_config() -> http_config.Config {
  let defaults = http_config.default()
  http_config.Config(
    ..defaults,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
    ),
  )
}
