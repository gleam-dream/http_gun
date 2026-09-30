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
import http_gun/config as http_config
import http_gun/fixture
import http_gun/testing
import llm_wire/config
import llm_wire/provider
import llm_wire/provider/openai
import llm_wire/session
import llm_wire/types

pub type Error {
  Http(http_gun.Failure)
  Provider(types.WireError)
  Status(Int)
  InvalidSse
  Incomplete
}

fn prepare(
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
      [#("content-type", "application/json"), #("accept", "text/event-stream")],
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
  use req <- result.try(prepare(settings, model, prompt))
  use reply <- result.try(http_gun.send(client, req) |> result.map_error(Http))
  use Nil <- result.try(case reply.response.status {
    200 -> Ok(Nil)
    code -> Error(Status(code))
  })
  use bytes <- result.try(
    bit_array.to_string(reply.response.body)
    |> result.map_error(fn(_) { InvalidSse }),
  )
  use reducer <- result.try(
    provider.new_reducer(config.adapter(settings), config.limits(settings), [])
    |> result.map_error(Provider),
  )
  step(string.split(bytes, "\n\n"), reducer)
}

fn step(
  events: List(String),
  reducer: provider.Reducer,
) -> Result(provider.Terminal, Error) {
  case provider.terminal(reducer), events {
    Some(terminal), _ -> Ok(terminal)
    None, [] -> Error(Incomplete)
    None, ["", ..rest] -> step(rest, reducer)
    None, [event, ..rest] -> {
      use Nil <- result.try(case string.byte_size(event) <= 65_536 {
        True -> Ok(Nil)
        False -> Error(InvalidSse)
      })
      let lines = string.split(event, "\n")
      let name =
        list.find(lines, fn(line) { string.starts_with(line, "event: ") })
        |> result.map(fn(line) { string.drop_start(line, 7) })
        |> option.from_result
      use data <- result.try(
        list.find(lines, fn(line) { string.starts_with(line, "data: ") })
        |> result.map_error(fn(_) { InvalidSse }),
      )
      use #(next, _) <- result.try(
        provider.step(
          reducer,
          provider.Event(name, string.drop_start(data, 6), None, None),
        )
        |> result.map_error(Provider),
      )
      step(rest, next)
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
