import gleam/dynamic.{type Dynamic}
import gleam/erlang/process.{type Pid}
import http_gun/config.{type Negotiated, type Protocol, type Trust}
import http_gun/error

pub type Stream

pub type Event {
  Up(Pid, Negotiated)
  Down(Pid, error.TransportCause)
  Capacity(Pid, Int)
  Head(Stream, Bool, Int, List(#(String, String)))
  Data(Stream, Bool, BitArray)
  Trailers(Stream, List(#(String, String)))
  Failed(Stream, error.TransportCause)
  Inform(Stream, List(#(String, String)))
  Ignore
}

@external(erlang, "http_gun_ffi", "decode")
pub fn decode(value: Dynamic) -> Event

@external(erlang, "http_gun_ffi", "start")
pub fn start() -> Result(Nil, Nil)

@external(erlang, "http_gun_ffi", "open")
pub fn open(
  host: String,
  port: Int,
  tls: Bool,
  protocol: Protocol,
  trust: Trust,
  timeout: Int,
  header_count: Int,
) -> Result(Pid, error.TransportCause)

@external(erlang, "http_gun_ffi", "request")
pub fn request(
  connection: Pid,
  method: String,
  path: String,
  headers: List(#(String, String)),
  body: BitArray,
) -> Result(Stream, error.TransportCause)

@external(erlang, "http_gun_ffi", "credit")
pub fn credit(connection: Pid, stream: Stream, amount: Int) -> Nil

@external(erlang, "http_gun_ffi", "cancel")
pub fn cancel(connection: Pid, stream: Stream) -> Nil

@external(erlang, "http_gun_ffi", "close")
pub fn close(connection: Pid) -> Nil

@external(erlang, "http_gun_ffi", "now")
pub fn now() -> Int

@external(erlang, "http_gun_ffi", "scoped")
pub fn scoped(run: fn() -> value, cleanup: fn() -> Nil) -> value

@external(erlang, "http_gun_ffi", "on_exception")
pub fn on_exception(run: fn() -> value, cleanup: fn() -> Nil) -> value

// ExitReason decoding and raw terms remain at this interoperability boundary.
pub fn exit_cause(reason: process.ExitReason) -> error.TransportCause {
  case reason {
    process.Normal -> error.PeerClosed
    process.Killed -> error.UnknownTransport
    process.Abnormal(value) -> transport_cause(value)
  }
}

@external(erlang, "http_gun_ffi", "cause")
fn transport_cause(value: Dynamic) -> error.TransportCause
