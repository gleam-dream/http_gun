//// The Gun event handler of a signer identity reports a signing failure
//// only for the opening handshake. A refusal during a later TLS 1.2
//// renegotiation leaves the connection's flag set; any later termination
//// must still be reported with its own reason.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom
import gleeunit/should

@external(erlang, "http_gun_event_handler_test_ffi", "terminated_after_handshake")
fn terminated_after_handshake(succeeded: Bool, refused: Bool) -> Dynamic

fn reported(succeeded: Bool, refused: Bool) -> Dynamic {
  terminated_after_handshake(succeeded, refused)
}

fn atom_named(name: String) -> Dynamic {
  atom.to_dynamic(atom.create(name))
}

pub fn failed_opening_handshake_reports_the_signer_refusal_test() {
  reported(False, True) |> should.equal(atom_named("client_signing_failed"))
}

pub fn failed_opening_handshake_without_refusal_keeps_its_reason_test() {
  reported(False, False) |> should.equal(atom_named("closed"))
}

pub fn refusal_after_the_opening_handshake_keeps_the_termination_reason_test() {
  reported(True, True) |> should.equal(atom_named("closed"))
}

pub fn opened_connection_keeps_the_termination_reason_test() {
  reported(True, False) |> should.equal(atom_named("closed"))
}
