import dream_http_client/client as dream
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/atom
import gleam/http
import gleam/http/request
import gleam/list
import gleam/result
import gleam/string
import gleam/yielder
import http_gun
import http_gun/body
import http_gun/config
import http_gun/destination

pub type Client {
  Gun(http_gun.Client)
  Dream(dream.HttpProfile)
}

pub type Reply {
  Reply(
    status: Int,
    headers: List(#(String, String)),
    bytes: BitArray,
    trailers: List(#(String, String)),
    branch: String,
  )
}

pub fn start(name: String, connections: Int) -> Client {
  case name {
    "gun" -> {
      let c = local_config()
      let assert Ok(client) =
        http_gun.start(
          config.Config(
            ..c,
            deadline_ms: 60_000,
            trust: config.CustomCa("test/fixtures/ca.crt"),
            limits: config.Limits(
              ..c.limits,
              connections: connections,
              per_origin: connections,
              active: 1024,
              waiting: 1024,
              chunk_bytes: 524_288,
              queue_bytes: 1_048_576,
            ),
          ),
        )
      Gun(client)
    }
    _ -> {
      let assert Ok(profile) =
        dream.start_profile(atom.create("comparison_profile"), connections)
      Dream(profile)
    }
  }
}

pub fn stop(client: Client) -> Nil {
  case client {
    Gun(client) -> {
      let _ = http_gun.stop(client)
      Nil
    }
    Dream(profile) -> {
      let _ = dream.stop_profile(profile)
      Nil
    }
  }
}

pub fn gun_request(port: Int, tls: Bool) -> request.Request(BitArray) {
  request.new()
  |> request.set_scheme(case tls {
    True -> http.Https
    False -> http.Http
  })
  |> request.set_host("localhost")
  |> request.set_port(port)
  |> request.set_path("/")
  |> request.set_body(<<>>)
}

pub fn dream_request(
  profile: dream.HttpProfile,
  port: Int,
  tls: Bool,
) -> dream.ClientRequest {
  dream.new()
  |> dream.use_profile(profile)
  |> dream.scheme(case tls {
    True -> http.Https
    False -> http.Http
  })
  |> dream.host("localhost")
  |> dream.port(port)
  |> dream.path("/")
  |> dream.timeout(60_000)
  |> dream.connection_timeout(5000)
  |> dream.follow_redirects(False)
  |> dream.certificate_authority_file("test/fixtures/ca.crt")
}

pub fn from_dream(reply: dream.HttpResponse, branch: String) -> Reply {
  let headers = list.map(reply.headers, fn(h) { #(h.name, h.value) })
  Reply(reply.status, headers, bit_array.from_string(reply.body), [], branch)
}

pub fn send(client: Client, port: Int, tls: Bool) -> Result(Reply, String) {
  case client {
    Gun(client) ->
      http_gun.send(client, gun_request(port, tls))
      |> result.map(fn(r) {
        Reply(
          r.response.status,
          r.response.headers,
          r.response.body,
          r.trailers,
          "ok",
        )
      })
      |> result.map_error(string.inspect)
    Dream(profile) ->
      case dream.send(dream_request(profile, port, tls)) {
        Ok(reply) -> Ok(from_dream(reply, "ok"))
        Error(dream.ResponseError(reply)) ->
          Ok(from_dream(reply, "response_error"))
        Error(e) -> Error(string.inspect(e))
      }
  }
}

@external(erlang, "http_gun_measure_ffi", "pause")
fn pause(ms: Int) -> Nil

fn pace(total: Int, bytes: Int, slow: Bool) -> Nil {
  case slow {
    True -> pause({ { total + bytes } / 65_536 - total / 65_536 } * 2)
    False -> Nil
  }
}

pub fn stream(
  client: Client,
  port: Int,
  slow: Bool,
  first: fn() -> Nil,
) -> Result(Int, String) {
  case client {
    Gun(client) ->
      case
        http_gun.with_response(client, gun_request(port, False), fn(r) {
          drain(r.body, 0, slow, first)
        })
      {
        Ok(result) -> result
        Error(e) -> Error(string.inspect(e))
      }
    Dream(profile) ->
      dream.stream_yielder(dream_request(profile, port, False))
      |> yielder.fold(Ok(0), fn(acc, event) {
        use total <- result.try(acc)
        use bytes <- result.try(event)
        case total {
          0 -> first()
          _ -> Nil
        }
        let size = bytes_tree.byte_size(bytes)
        pace(total, size, slow)
        Ok(total + size)
      })
  }
}

fn drain(
  stream: body.Body,
  total: Int,
  slow: Bool,
  first: fn() -> Nil,
) -> Result(Int, String) {
  use event <- result.try(
    body.next(stream, 60_000) |> result.map_error(string.inspect),
  )
  case event {
    body.End(_) -> Ok(total)
    body.Chunk(bytes) -> {
      case total {
        0 -> first()
        _ -> Nil
      }
      let size = bit_array.byte_size(bytes)
      pace(total, size, slow)
      drain(stream, total + size, slow, first)
    }
  }
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  let defaults = config.default()
  config.Config(
    ..defaults,
    destination: destination.Policy(
      ..defaults.destination,
      allow_loopback: True,
    ),
  )
}
