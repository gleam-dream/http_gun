//// A deliberately small text-only integration. All provider semantics live here
//// and in LLM Wire; HTTP Gun sees only ordinary HTTP values.

import gleam/bit_array
import gleam/http
import gleam/http/request
import gleam/http/response
import gleam/list
import gleam/option.{None, Some}
import gleam/result
import gleam/string
import http_gun
import http_gun/body
import http_gun/config as http_config
import http_gun/error as http_error
import http_gun/fixture
import http_gun/testing
import http_gun_llm_consumer/framer
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

pub type Decision {
  Continue
  Stop
}

pub type Error {
  Http(http_gun.Failure, types.RetryEvidence)
  Provider(types.WireError)
  Status(Int, option.Option(String))
  Compressed(String)
  Cancelled(types.RetryEvidence)
  InvalidSse
  Incomplete
}

pub fn prepare(
  settings: config.Config,
  model: types.ModelId,
  prompt: String,
) -> Result(request.Request(BitArray), Error) {
  let input = types.new_request(model, [types.UserMessage(prompt)])
  // LLM Wire admission runs before the HTTP client can submit anything.
  use admitted <- result.try(
    session.prepare(settings, input) |> result.map_error(Provider),
  )
  let adapter = config.adapter(settings)
  use encoded <- result.try(
    provider.encode(adapter, input, [], None) |> result.map_error(Provider),
  )
  use base <- result.try(
    request.to(types.endpoint_to_string(provider.endpoint(adapter)))
    |> result.map_error(fn(_) { InvalidSse }),
  )
  let headers =
    list.append(
      list.map(provider.headers(adapter), fn(pair) {
        #(string.lowercase(pair.0), pair.1)
      }),
      [
        #("content-type", "application/json"),
        #("accept", "text/event-stream"),
        #("accept-encoding", "identity"),
      ],
    )
  Ok(
    request.Request(
      ..base,
      method: http.Post,
      path: base.path <> encoded.path,
      headers: headers,
      body: bit_array.from_string(session.prepared_request_json(admitted)),
    ),
  )
}

pub fn text(
  client: http_gun.Client,
  settings: config.Config,
  model: types.ModelId,
  prompt: String,
) -> Result(provider.Terminal, Error) {
  stream(client, settings, model, prompt, fn(_) { Continue })
}

/// Progress runs synchronously in the consuming process. Stop or scope exit
/// cancels locally. This example does not implement LLM Wire's session runtime.
pub fn stream(
  client: http_gun.Client,
  settings: config.Config,
  model: types.ModelId,
  prompt: String,
  on_progress: fn(types.StreamProgress) -> Decision,
) -> Result(provider.Terminal, Error) {
  use req <- result.try(prepare(settings, model, prompt))
  http_gun.with_response(client, req, fn(reply) {
    use Nil <- result.try(case reply.status {
      200 -> Ok(Nil)
      code -> Error(Status(code, header(reply.headers, "retry-after")))
    })
    use Nil <- result.try(case header(reply.headers, "content-encoding") {
      None | Some("identity") -> Ok(Nil)
      Some(encoding) -> Error(Compressed(encoding))
    })
    use reducer <- result.try(
      provider.new_reducer(
        config.adapter(settings),
        config.limits(settings),
        [],
      )
      |> result.map_error(Provider),
    )
    read(
      reply.body,
      framer.new(config.limits(settings)),
      reducer,
      settings,
      0,
      on_progress,
    )
  })
  |> result.map_error(fn(failure) {
    Http(
      failure,
      types.RetryEvidence(
        case failure.evidence {
          http_error.NotSubmitted -> types.NoRequestSent
          http_error.MayHaveBeenSent -> types.RequestMayHaveReachedProvider
        },
        False,
        False,
      ),
    )
  })
  |> result.flatten
}

fn header(
  headers: List(#(String, String)),
  name: String,
) -> option.Option(String) {
  headers |> list.key_find(name) |> option.from_result
}

fn evidence(reducer: provider.Reducer, bytes: Int) -> types.RetryEvidence {
  let retry =
    provider.retry_evidence(reducer, types.RequestMayHaveReachedProvider)
  types.RetryEvidence(..retry, response_bytes_observed: bytes > 0)
}

fn read(
  stream: body.Body,
  framing: framer.Framer,
  reducer: provider.Reducer,
  settings: config.Config,
  received: Int,
  on_progress: fn(types.StreamProgress) -> Decision,
) -> Result(provider.Terminal, Error) {
  case provider.terminal(reducer) {
    Some(terminal) -> Ok(terminal)
    None -> {
      // The application makes an idle wait terminal by leaving the scope.
      // The client's overall deadline includes admission and connection time.
      use part <- result.try(
        body.next(stream, config.deadlines(settings).idle_timeout_ms)
        |> result.map_error(fn(failure) {
          Http(failure, evidence(reducer, received))
        }),
      )
      case part {
        body.End(_) -> Error(Incomplete)
        body.Chunk(bytes) -> {
          let received = received + bit_array.byte_size(bytes)
          let limit = config.limits(settings).response_body_bytes_limit
          use Nil <- result.try(case received <= limit {
            True -> Ok(Nil)
            False ->
              Error(
                Provider(types.ResourceLimitExceeded(
                  "response_body_bytes_limit",
                  limit,
                  received,
                )),
              )
          })
          use #(framing, events) <- result.try(
            framer.feed(framing, bytes) |> result.map_error(Provider),
          )
          use reducer <- result.try(step(events, reducer, received, on_progress))
          read(stream, framing, reducer, settings, received, on_progress)
        }
      }
    }
  }
}

fn step(
  events: List(framer.ServerSentEvent),
  reducer: provider.Reducer,
  received: Int,
  on_progress: fn(types.StreamProgress) -> Decision,
) -> Result(provider.Reducer, Error) {
  case provider.terminal(reducer), events {
    Some(_), _ | _, [] -> Ok(reducer)
    None, [event, ..rest] -> {
      use #(next, progress) <- result.try(
        provider.step(
          reducer,
          provider.Event(event.event, event.data, event.id, event.retry),
        )
        |> result.map_error(Provider),
      )
      use Nil <- result.try(deliver(
        progress,
        on_progress,
        evidence(next, received),
      ))
      step(rest, next, received, on_progress)
    }
  }
}

fn deliver(
  progress: List(types.StreamProgress),
  on_progress: fn(types.StreamProgress) -> Decision,
  retry: types.RetryEvidence,
) -> Result(Nil, Error) {
  case progress {
    [] -> Ok(Nil)
    [item, ..rest] ->
      case on_progress(item) {
        Continue -> deliver(rest, on_progress, retry)
        Stop -> Error(Cancelled(retry))
      }
  }
}

pub fn main() -> Nil {
  let assert Ok(key) = types.api_key("offline-fixture-key")
  let settings = config.openai(openai.options(key))
  let assert Ok(model) = types.model_id("fixture-model")
  let assert Ok(req) = prepare(settings, model, "Hello")
  let events =
    "event: response.output_item.added\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"message\"}}\n\nevent: response.output_text.delta\ndata: {\"output_index\":0,\"item_id\":\"item_1\",\"delta\":\"Hello\"}\n\nevent: response.output_item.done\ndata: {\"output_index\":0,\"item\":{\"id\":\"item_1\",\"type\":\"message\"}}\n\nevent: response.completed\ndata: {\"response\":{\"id\":\"r1\",\"status\":\"completed\"}}\n\n"
  let exchange =
    fixture.Exchange(
      req,
      fixture.Respond(
        response.new(200) |> response.set_body([bit_array.from_string(events)]),
        fixture.Complete([]),
      ),
    )
  let assert Ok(client) = testing.start(http_config.default(), [exchange])
  let assert Ok(provider.Text("Hello", _)) =
    text(client, settings, model, "Hello")
  let assert Ok(Nil) = http_gun.stop(client)
  Nil
}
