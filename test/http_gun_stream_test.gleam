import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleeunit/should
import http_gun
import http_gun/body
import http_gun/config
import http_gun/error

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "send_control")
fn emit(server: process.Pid, bytes: BitArray) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn req(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

pub fn local_timeout_preserves_stream_and_copies_share_cursor_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  let assert Ok(response) = http_gun.open(client, req(port))
  let copy = response.body
  body.next(copy, 0)
  |> should.equal(
    Error(error.Failure(error.ReadTimeout, error.MayHaveBeenSent)),
  )
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  body.next(response.body, 1000) |> should.equal(Ok(body.Chunk(<<"abc":utf8>>)))
  body.close(copy) |> should.equal(Ok(Nil))
  body.close(response.body) |> should.equal(Ok(Nil))
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

pub fn scoped_early_exit_closes_socket_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  http_gun.with_response(client, req(port), fn(_) { "caller value" })
  |> should.equal(Ok("caller value"))
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

pub fn overall_deadline_is_terminal_test() {
  let #(port, server) = controlled()
  let settings = config.default()
  let assert Ok(client) =
    http_gun.start(config.Config(..settings, deadline_ms: 100))
  let assert Ok(response) = http_gun.open(client, req(port))
  body.next(response.body, 1000)
  |> should.equal(
    Error(error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent)),
  )
  body.next(response.body, 1000)
  |> should.equal(
    Error(error.Failure(error.DeadlineExceeded, error.MayHaveBeenSent)),
  )
  closed(server) |> should.be_true
  let _ = body.close(response.body)
  let _ = http_gun.stop(client)
}

pub fn owner_death_closes_socket_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  let ready = process.new_subject()
  let owner =
    process.spawn_unlinked(fn() {
      let assert Ok(response) = http_gun.open(client, req(port))
      process.send(ready, response.body)
      process.sleep_forever()
    })
  let assert Ok(stream) = process.receive(ready, 1000)
  body.next(stream, 1)
  |> should.equal(Error(error.Failure(error.WrongOwner, error.MayHaveBeenSent)))
  process.kill(owner)
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

pub fn buffered_limit_closes_socket_test() {
  let #(port, server) = controlled()
  let settings = config.default()
  let settings =
    config.Config(
      ..settings,
      limits: config.Limits(..settings.limits, collect_bytes: 2),
    )
  let assert Ok(client) = http_gun.start(settings)
  let response = http_gun.open(client, req(port))
  emit(server, <<"3\r\nabc\r\n":utf8>>)
  let assert Ok(response) = response
  body.collect(response.body, 2)
  |> should.equal(
    Error(error.Failure(
      error.LimitExceeded("collection", 2),
      error.MayHaveBeenSent,
    )),
  )
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

@external(erlang, "http_gun_scope_test_ffi", "raised")
fn raised(run: fn() -> a) -> Bool

@external(erlang, "erlang", "error")
fn raise(reason: ScopeProbe) -> Nil

type ScopeProbe {
  ScopeProbe
}

pub fn exception_scope_cleanup_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  raised(fn() {
    http_gun.with_response(client, req(port), fn(_) { raise(ScopeProbe) })
  })
  |> should.be_true
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

pub fn conflicting_reader_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(config.default())
  let ready = process.new_subject()
  let reading = process.new_subject()
  let finished = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let command = process.new_subject()
      let assert Ok(response) = http_gun.open(client, req(port))
      process.send(ready, #(response.body, command))
      let assert Ok(Nil) = process.receive(command, 1000)
      process.send(reading, Nil)
      process.send(finished, body.next(response.body, 2000))
    })
  let assert Ok(#(stream, command)) = process.receive(ready, 1000)
  process.send(command, Nil)
  let assert Ok(Nil) = process.receive(reading, 1000)
  await_conflict(stream, 1000) |> should.be_true
  let _ = body.close(stream)
  let assert Ok(_) = process.receive(finished, 1000)
  closed(server) |> should.be_true
  let _ = http_gun.stop(client)
}

fn await_conflict(stream: body.Body, remaining: Int) -> Bool {
  case remaining {
    0 -> False
    _ ->
      case body.next(stream, 0) {
        Error(error.Failure(error.ReadConflict, _)) -> True
        Error(error.Failure(error.WrongOwner, _)) ->
          await_conflict(stream, remaining - 1)
        _ -> False
      }
  }
}
