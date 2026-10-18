//// Destination policies: the three local setups, plaintext rules and one
//// client shared by tenants that need different destinations.

import gleam/http/request
import gleam/int
import http_gun
import http_gun/config
import http_gun/destination
import http_gun/error

@external(erlang, "http_gun_test_server", "persistent")
fn server() -> Int

pub fn main() -> Nil {
  let port = server()
  let req = local_request(port)

  // Three local setups: public and loopback, loopback only, and one pinned
  // host and port.
  let public_and_loopback = config.default() |> config.allow_loopback
  let loopback_only =
    config.default() |> config.with_destination(destination.loopback_only())
  let pinned =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.only_hosts(["127.0.0.1:" <> int.to_string(port)]),
    )
  send_ok(public_and_loopback, req)
  send_ok(loopback_only, req)
  send_ok(pinned, req)

  // A request to another port than the pinned one is refused before sending.
  let assert Ok(client) = http_gun.start(pinned)
  let assert Error(failure) = http_gun.send(client, local_request(port + 1))
  let assert error.DestinationRejected(destination.HostNotAllowed) =
    error.reason(failure)
  let assert error.NotSent = error.evidence(failure)
  http_gun.stop(client)

  // `RequireTls` refuses plaintext `http://` after checking the destination.
  let assert Ok(tls_only) =
    config.default()
    |> config.with_destination(
      destination.loopback_only()
      |> destination.with_plaintext(destination.RequireTls),
    )
    |> http_gun.start
  let assert Error(plaintext) = http_gun.send(tls_only, req)
  let assert error.Refused = error.kind(plaintext)
  let assert error.DestinationRejected(destination.PlaintextRefused(
    destination.Loopback,
  )) = error.reason(plaintext)
  http_gun.stop(tls_only)

  tenants(port)
}

type Tier {
  PublicTier
  InternalTier(hosts: List(String))
}

// A view can only narrow the client's policy, so a client shared by tenants
// admits their union and requires every call to choose a destination.
fn for_tenant(client: http_gun.Client, tier: Tier) -> http_gun.Client {
  case tier {
    PublicTier -> client |> http_gun.with_destination(destination.default())
    InternalTier(hosts) ->
      client
      |> http_gun.with_destination(
        destination.loopback_only() |> destination.only_hosts(hosts),
      )
  }
}

fn tenants(port: Int) -> Nil {
  let req = local_request(port)
  let assert Ok(client) =
    config.default()
    |> config.allow_loopback
    |> config.require_view_destination
    |> http_gun.start
  let internal = InternalTier(["127.0.0.1:" <> int.to_string(port)])
  let assert Ok(_) = for_tenant(client, internal) |> http_gun.send(req)
  let assert Error(public) =
    for_tenant(client, PublicTier) |> http_gun.send(req)
  let assert error.DestinationRejected(destination.AddressRefused(
    destination.Loopback,
  )) = error.reason(public)
  // A call that skips the view fails closed, before resolving or sending.
  let assert Error(unviewed) = http_gun.send(client, req)
  let assert error.ViewDestinationRequired = error.reason(unviewed)
  let assert error.NotSent = error.evidence(unviewed)
  http_gun.stop(client)
}

fn send_ok(settings: config.Config, req: request.Request(BitArray)) -> Nil {
  let assert Ok(client) = http_gun.start(settings)
  let assert Ok(_) = http_gun.send(client, req)
  http_gun.stop(client)
}

fn local_request(port: Int) -> request.Request(BitArray) {
  let assert Ok(req) = request.to("http://127.0.0.1:" <> int.to_string(port))
  request.set_body(req, <<>>)
}
