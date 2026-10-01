import comparison_adapter as adapter
import dream_http_client/client as dream
import dream_http_client/recorder as dream_recorder
import gleam/bit_array
import gleam/bytes_tree
import gleam/erlang/process
import gleam/io
import gleam/json
import gleam/list
import gleam/string
import gleam/yielder
import http_gun
import http_gun/body
import http_gun/cassette
import http_gun/config
import http_gun/destination
import http_gun/recording
import simplifile

@external(erlang, "comparison_ffi", "arguments")
fn arguments() -> List(String)

@external(erlang, "comparison_ffi", "sequence")
fn sequence() -> Int

@external(erlang, "http_gun_test_server", "serve")
fn serve(bytes: BitArray) -> Int

@external(erlang, "http_gun_tls_test_server", "start")
fn tls() -> Int

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "send_control")
fn emit(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

@external(erlang, "http_gun_test_server", "temp_path")
fn temp_path() -> String

fn note(name: String, label: String, value: String) -> Nil {
  io.println(
    json.object([
      #("client", json.string(name)),
      #("case", json.string(label)),
      #("observation", json.string(value)),
    ])
    |> json.to_string,
  )
}

fn show(reply: Result(adapter.Reply, String)) -> String {
  case reply {
    Ok(r) ->
      string.inspect(#(r.branch, r.status, r.headers, r.bytes, r.trailers))
    Error(e) -> "failure: " <> e
  }
}

fn check_buffered(
  client: adapter.Client,
  label: String,
  reply: Result(adapter.Reply, String),
) -> Nil {
  case client, label, reply {
    adapter.Dream(_), "binary200", Error(message) -> {
      let assert True = string.contains(message, "convert response to string")
      Nil
    }
    _, _, Ok(r) -> {
      let expected_status = case label {
        "created201" -> 201
        "status429" -> 429
        "empty204" -> 204
        _ -> 200
      }
      let assert True = r.status == expected_status
      let expected_body = case label {
        "empty204" -> <<>>
        "binary200" -> <<0, 255, 128>>
        _ -> <<"abc":utf8>>
      }
      let assert True = r.bytes == expected_body
      let expected_branch = case client, label {
        adapter.Dream(_), "status429" -> "response_error"
        _, _ -> "ok"
      }
      let assert True = r.branch == expected_branch
      case label {
        "duplicates-and-trailers" -> {
          let assert [#("x-dup", "a"), #("x-dup", "b")] =
            list.filter(r.headers, fn(header) { header.0 == "x-dup" })
          case client {
            adapter.Gun(_) -> {
              let assert [#("x-end", "yes")] = r.trailers
              Nil
            }
            adapter.Dream(_) -> {
              let assert Ok("yes") = list.key_find(r.headers, "x-end")
              Nil
            }
          }
        }
        _ -> Nil
      }
    }
    _, _, _ -> panic as "unexpected buffered contract result"
  }
}

fn check_pull(
  client: adapter.Client,
  label: String,
  reply: Result(Int, String),
) -> Nil {
  let expected = case client, label {
    adapter.Dream(_), "created201" -> Error("HTTP 201: abc")
    adapter.Dream(_), "status429" -> Error("HTTP 429: abc")
    _, "empty204" -> Ok(0)
    _, _ -> Ok(3)
  }
  let assert True = reply == expected
  Nil
}

fn first(client: adapter.Client, port: Int) -> Int {
  case client {
    adapter.Gun(client) -> {
      let assert Ok(Ok(body.Chunk(bytes))) =
        http_gun.with_response(client, adapter.gun_request(port, False), fn(r) {
          body.next(r.body, 1000)
        })
      bit_array.byte_size(bytes)
    }
    adapter.Dream(profile) -> {
      let assert [Ok(bytes)] =
        dream.stream_yielder(adapter.dream_request(profile, port, False))
        |> yielder.take(1)
        |> yielder.to_list
      bytes_tree.byte_size(bytes)
    }
  }
}

fn abandon(client: adapter.Client, port: Int) -> Int {
  case client {
    adapter.Gun(client) -> {
      let assert Ok(reply) =
        http_gun.open(client, adapter.gun_request(port, False))
      let assert Ok(body.Chunk(bytes)) = body.next(reply.body, 1000)
      // The worker exits with an explicitly owned body still open.
      bit_array.byte_size(bytes)
    }
    adapter.Dream(_) -> first(client, port)
  }
}

fn early(client: adapter.Client, owner_dies: Bool) -> Bool {
  let #(port, server) = controlled()
  let _ =
    process.spawn(fn() {
      emit(
        server,
        bit_array.from_string(
          "4000\r\n" <> string.repeat("x", 16_384) <> "\r\n",
        ),
      )
    })
  case owner_dies {
    False -> {
      let assert True = first(client, port) > 0
      Nil
    }
    True -> {
      let done = process.new_subject()
      let _ = process.spawn(fn() { process.send(done, abandon(client, port)) })
      let assert Ok(bytes) = process.receive(done, 5000)
      let assert True = bytes > 0
      Nil
    }
  }
  closed(server)
}

fn callback_cancel(profile: dream.HttpProfile) -> Bool {
  let #(port, server) = controlled()
  let done = process.new_subject()
  let req =
    adapter.dream_request(profile, port, False)
    |> dream.on_stream_chunk(fn(bytes) { process.send(done, bytes) })
  let assert Ok(handle) = dream.start_stream(req)
  emit(
    server,
    bit_array.from_string("4000\r\n" <> string.repeat("x", 16_384) <> "\r\n"),
  )
  let assert Ok(_) = process.receive(done, 2000)
  dream.cancel_stream_handle(handle)
  dream.await_stream(handle)
  closed(server)
}

fn exchange(client: http_gun.Client, port: Int) -> String {
  case http_gun.send(client, adapter.gun_request(port, False)) {
    Ok(reply) -> string.inspect(reply.response.body)
    Error(e) -> string.inspect(e)
  }
}

fn recording_case(name: String, client: adapter.Client, repeated: Bool) -> Nil {
  let port = case repeated {
    True -> sequence()
    False ->
      serve(<<
        "HTTP/1.1 200 OK\r\nConnection: close\r\nContent-Length: 3\r\n\r\nabc":utf8,
      >>)
  }
  let destination = temp_path()
  let label = case repeated {
    True -> "record-identical-sequence"
    False -> "record-offline-roundtrip"
  }
  case client {
    adapter.Gun(_) -> {
      let assert Ok(rec) =
        cassette.record(local_config(), destination, recording.default())
      let a = exchange(rec.client, port)
      let b = case repeated {
        True -> exchange(rec.client, port)
        False -> "not requested"
      }
      let assert Ok(_) = cassette.finish(rec.recording)
      let _ = http_gun.stop(rec.client)
      let assert Ok(tape) = cassette.load(destination, 100_000)
      let assert Ok(replay) = cassette.playback(tape, local_config())
      let a2 = exchange(replay, port)
      let b2 = case repeated {
        True -> exchange(replay, port)
        False -> "not requested"
      }
      let end = exchange(replay, port)
      note(name, label, string.inspect(#(a, b, a2, b2, end)))
      let assert True = a == string.inspect(<<"abc":utf8>>) && a2 == a
      let assert True = b2 == b
      let assert True = end == "Failure(FixtureExhausted, NotSubmitted)"
      case repeated {
        True -> {
          let assert True = b == string.inspect(<<"xyz":utf8>>)
          Nil
        }
        False -> Nil
      }
      let _ = http_gun.stop(replay)
      Nil
    }
    adapter.Dream(profile) -> {
      let assert Ok(rec) =
        dream_recorder.new()
        |> dream_recorder.directory(destination)
        |> dream_recorder.mode("record")
        |> dream_recorder.start
      let req = adapter.dream_request(profile, port, False)
      let a = dream.send(dream.recorder(req, rec))
      let b = case repeated {
        True -> dream.send(dream.recorder(req, rec))
        False -> a
      }
      let _ = dream_recorder.stop(rec)
      let assert Ok(replay) =
        dream_recorder.new()
        |> dream_recorder.directory(destination)
        |> dream_recorder.mode("playback")
        |> dream_recorder.start
      let a2 = dream.send(dream.recorder(req, replay))
      let b2 = case repeated {
        True -> dream.send(dream.recorder(req, replay))
        False -> a2
      }
      let end = dream.send(dream.recorder(req, replay))
      note(name, label, string.inspect(#(a, b, a2, b2, end)))
      let assert Ok(dream.HttpResponse(status: 200, body: "abc", ..)) = a
      case repeated {
        True -> {
          let assert Ok(dream.HttpResponse(status: 200, body: "xyz", ..)) = b
          list.each([a2, b2, end], fn(response) {
            let assert Error(dream.RequestError(message)) = response
            let assert True =
              string.contains(message, "Ambiguous recording match")
            Nil
          })
        }
        False ->
          list.each([a2, end], fn(response) {
            let assert Ok(dream.HttpResponse(status: 200, body: "abc", ..)) =
              response
            Nil
          })
      }
      let _ = dream_recorder.stop(replay)
      Nil
    }
  }
  let _ = simplifile.delete(destination)
  Nil
}

pub fn main() {
  let assert [name] = arguments()
  let client = adapter.start(name, 4)
  let samples = [
    #("created201", <<
      "HTTP/1.1 201 Created\r\nContent-Length: 3\r\n\r\nabc":utf8,
    >>),
    #("status429", <<
      "HTTP/1.1 429 Limited\r\nContent-Length: 3\r\n\r\nabc":utf8,
    >>),
    #("empty204", <<"HTTP/1.1 204 No Content\r\n\r\n":utf8>>),
    #("binary200", <<
      "HTTP/1.1 200 OK\r\nContent-Length: 3\r\n\r\n":utf8,
      0,
      255,
      128,
    >>),
    #("duplicates-and-trailers", <<
      "HTTP/1.1 200 OK\r\nX-Dup: a\r\nX-Dup: b\r\nTransfer-Encoding: chunked\r\nTrailer: x-end\r\n\r\n3\r\nabc\r\n0\r\nx-end: yes\r\n\r\n":utf8,
    >>),
  ]
  list.each(samples, fn(sample) {
    let reply = adapter.send(client, serve(sample.1), False)
    note(name, sample.0, show(reply))
    check_buffered(client, sample.0, reply)
  })
  list.each(samples, fn(sample) {
    let reply = adapter.stream(client, serve(sample.1), False, fn() { Nil })
    note(name, "pull-" <> sample.0, string.inspect(reply))
    check_pull(client, sample.0, reply)
  })
  let secured = adapter.send(client, tls(), True)
  note(name, "custom-ca-tls", show(secured))
  check_buffered(client, "custom-ca-tls", secured)
  let early_closed = early(client, False)
  note(name, "early-pull-closes-within-2s", string.inspect(early_closed))
  let owner_closed = early(client, True)
  note(name, "pull-owner-exit-closes-within-2s", string.inspect(owner_closed))
  let scoped = case client {
    adapter.Gun(_) -> True
    adapter.Dream(_) -> False
  }
  let assert True = early_closed == scoped && owner_closed == scoped
  case client {
    adapter.Dream(profile) -> {
      let cancelled = callback_cancel(profile)
      note(
        name,
        "explicit-callback-cancel-closes-within-2s",
        string.inspect(cancelled),
      )
      let assert True = cancelled
      Nil
    }
    adapter.Gun(_) -> Nil
  }
  recording_case(name, client, False)
  recording_case(name, client, True)
  adapter.stop(client)
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
