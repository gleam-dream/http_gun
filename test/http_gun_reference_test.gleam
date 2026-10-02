//// Scenarios inspired by Gun flow_SUITE and Finch lifecycle tests.
//// Reference revisions/hashes: docs/evidence/adoption-review/reference-sources.json.

import gleam/bit_array
import gleam/erlang/process
import gleam/http/request
import gleam/int
import gleam/list
import gleeunit/should
import http_gun
import http_gun/config

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

pub fn exhausted_flow_finishes_trailers_and_reuses_h1_test() {
  let port = server()
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/flow-trailers")
  let req = request.set_body(req, <<>>)
  let c = local_config()
  let assert Ok(client) =
    http_gun.start(
      config.Config(
        ..c,
        limits: config.Limits(..c.limits, connections: 1, per_origin: 1),
      ),
    )
  let assert Ok(first) = http_gun.send(client, req)
  list.each(list.repeat(Nil, 24), fn(_) {
    let assert Ok(next) = http_gun.send(client, req)
    next.response.headers |> should.equal(first.response.headers)
    next.response.body |> should.equal(first.response.body)
    next.trailers |> should.equal([#("x-final", "yes"), #("x-final", "again")])
  })
  bit_array.byte_size(first.response.body) |> should.equal(25 * 4096)
  let assert Ok(Nil) = http_gun.stop(client)
}

@external(erlang, "http_gun_test_server", "controlled")
fn controlled() -> #(Int, process.Pid)

@external(erlang, "http_gun_test_server", "await_request")
fn requested(server: process.Pid) -> Nil

@external(erlang, "http_gun_test_server", "await_closed")
fn closed(server: process.Pid) -> Bool

fn request_at(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) =
    request.to("http://localhost:" <> int.to_string(port) <> "/")
  request.set_body(req, <<>>)
}

fn released(client: http_gun.Client, attempts: Int) -> Bool {
  let assert Ok(stats) = http_gun.snapshot(client)
  case stats.bodies == 0 && stats.waiting == 0, attempts {
    True, _ -> True
    False, 0 -> False
    False, _ -> released(client, attempts - 1)
  }
}

pub fn normal_owner_exit_releases_unfinished_body_test() {
  let #(port, server) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let opened = process.new_subject()
  let _ =
    process.spawn_unlinked(fn() {
      let assert Ok(_) = http_gun.open(client, request_at(port))
      process.send(opened, Nil)
      // Return normally without explicitly closing the still-active body.
    })
  let assert Ok(Nil) = process.receive(opened, 1000)
  closed(server) |> should.be_true
  released(client, 1000) |> should.be_true
  let assert Ok(Nil) = http_gun.stop(client)
}

pub fn batch_owner_loss_cancels_workers_and_releases_admission_test() {
  let #(a, first) = controlled()
  let #(b, second) = controlled()
  let assert Ok(client) = http_gun.start(local_config())
  let owner =
    process.spawn_unlinked(fn() {
      let _ = http_gun.batch(client, [request_at(a), request_at(b)], 2)
    })
  requested(first)
  requested(second)
  process.kill(owner)
  closed(first) |> should.be_true
  closed(second) |> should.be_true
  released(client, 1000) |> should.be_true
  let assert Ok(reply) = http_gun.send(client, request_at(server()))
  reply.response.body |> should.equal(<<"abc":utf8>>)
  let assert Ok(Nil) = http_gun.stop(client)
}

// These exercises connect only to explicitly permitted local test servers.
fn local_config() -> config.Config {
  config.default() |> config.allow_loopback
}
