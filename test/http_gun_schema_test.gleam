//// Cassette schema 3: byte-exact bodies, the shared layout, reading
//// schema 2, and upgrading.

import gleam/bit_array
import gleam/http/request
import gleam/http/response
import gleam/int
import gleam/list
import gleam/string
import gleeunit/should
import http_gun/cassette
import http_gun/testing

fn exchange_with(body: BitArray, chunks: List(BitArray)) -> testing.Exchange {
  let assert Ok(req) = request.to("http://offline.invalid/ask")
  testing.exchange(
    request.set_body(req, body),
    testing.Respond(response.Response(200, [], chunks), testing.Finished([])),
  )
}

// Bodies a cassette must give back byte for byte.
fn bodies() -> List(BitArray) {
  [
    <<>>,
    <<"one line":utf8>>,
    <<"ends with a newline\n":utf8>>,
    <<"two\nlines":utf8>>,
    <<"crlf\r\nline ends\r\n":utf8>>,
    <<"\n":utf8>>,
    <<"\n\n\n":utf8>>,
    <<"\r":utf8>>,
    <<"não é ASCII — 日本語\nsegunda linha\n":utf8>>,
    <<"data: {\"candidates\":[{\"text\":\"Olá\\n\"}]}\n\n":utf8>>,
    <<"{\n  \"n\": 1.0e5,\n  \"z\": -0,\n  \"a\": \"\\u00e9\"\n}\n":utf8>>,
    <<"tab\tand \"quotes\" and \\ backslash\n":utf8>>,
    <<0, 255, 10, 13>>,
  ]
}

pub fn every_body_reads_back_byte_for_byte_test() {
  let exchanges =
    list.map(bodies(), fn(body) { exchange_with(body, [body, <<"tail":utf8>>]) })
  let text = cassette.encode(testing.script(exchanges))
  let assert Ok(loaded) = cassette.parse(text, 1_000_000)
  list.zip(testing.exchanges(loaded), bodies())
  |> list.each(fn(pair) {
    let #(exchange, body) = pair
    testing.request(exchange).body |> should.equal(body)
    let assert testing.Respond(reply, _) = testing.reply(exchange)
    reply.body |> should.equal([body, <<"tail":utf8>>])
  })
}

// Generated bodies over a small alphabet that stresses line ends.
pub fn generated_bodies_read_back_byte_for_byte_test() {
  let alphabet = ["a", "\n", "\r", "é", " ", "\"", "\\", ""]
  let generated =
    int.range(0, 300, [], fn(acc, seed) {
      let body =
        int.range(0, seed % 9, "", fn(text, step) {
          let index = { seed * 7 + step * 13 } % list.length(alphabet)
          let assert Ok(piece) = list.drop(alphabet, index) |> list.first
          text <> piece
        })
      [bit_array.from_string(body), ..acc]
    })
  let text =
    cassette.encode(
      testing.script(
        list.map(generated, fn(body) { exchange_with(body, [body]) }),
      ),
    )
  let assert Ok(loaded) = cassette.parse(text, 10_000_000)
  list.map(testing.exchanges(loaded), fn(exchange) {
    testing.request(exchange).body
  })
  |> should.equal(generated)
}

pub fn schema_2_cassettes_keep_loading_test() {
  let schema_2 =
    "{\"http_gun\":2,\"exchanges\":[{\"request\":{\"method\":\"GET\",\"url\":\"http://offline.invalid/ask\",\"headers\":[],\"body\":{\"text\":\"a\\nb\"}},\"reply\":{\"kind\":\"response\",\"status\":200,\"headers\":[],\"chunks\":[{\"base64\":\"AP8=\"}],\"ending\":{\"kind\":\"finished\",\"trailers\":[]}}}]}"
  let assert Ok(loaded) = cassette.parse(schema_2, 10_000)
  let assert [exchange] = testing.exchanges(loaded)
  testing.request(exchange).body |> should.equal(<<"a\nb":utf8>>)
  let assert testing.Respond(reply, _) = testing.reply(exchange)
  reply.body |> should.equal([<<0, 255>>])

  // Upgrading turns text with newlines into lines, every byte kept.
  let with_newlines =
    string.replace(
      schema_2,
      "{\"base64\":\"AP8=\"}",
      "{\"text\":\"crlf\\r\\nends\\r\\n\"},{\"text\":\"trailing\\n\"},{\"text\":\"\\n\"}",
    )
  let assert Ok(original) = cassette.parse(with_newlines, 10_000)
  let assert Ok(upgraded) = cassette.upgrade(with_newlines, 10_000)
  string.contains(upgraded, "{\"lines\": [") |> should.be_true
  let assert Ok(reloaded) = cassette.parse(upgraded, 10_000)
  testing.exchanges(reloaded) |> should.equal(testing.exchanges(original))
  let assert [upgraded_exchange] = testing.exchanges(reloaded)
  let assert testing.Respond(upgraded_reply, _) =
    testing.reply(upgraded_exchange)
  upgraded_reply.body
  |> should.equal([
    <<"crlf\r\nends\r\n":utf8>>,
    <<"trailing\n":utf8>>,
    <<"\n":utf8>>,
  ])
}

pub fn lines_bodies_are_checked_test() {
  let body = fn(marker, value) {
    "{\"http_gun\":"
    <> marker
    <> ",\"exchanges\":[{\"request\":{\"method\":\"GET\",\"url\":\"http://offline.invalid/\",\"headers\":[],\"body\":"
    <> value
    <> "},\"reply\":{\"kind\":\"reject\",\"failure\":{\"name\":\"client_closed\",\"evidence\":\"not_sent\"}}}]}"
  }
  // Lines are a schema 3 kind, and need at least two strings.
  cassette.parse(body("2", "{\"lines\":[\"a\",\"b\"]}"), 10_000)
  |> should.equal(Error(cassette.Corrupt))
  cassette.parse(body("3", "{\"lines\":[\"a\"]}"), 10_000)
  |> should.equal(Error(cassette.Corrupt))
  cassette.parse(body("3", "{\"lines\":[]}"), 10_000)
  |> should.equal(Error(cassette.Corrupt))
  let assert Ok(loaded) =
    cassette.parse(body("3", "{\"lines\":[\"a\",\"\"]}"), 10_000)
  let assert [exchange] = testing.exchanges(loaded)
  testing.request(exchange).body |> should.equal(<<"a\n":utf8>>)
  // The first kind that decodes wins.
  let assert Ok(loaded) =
    cassette.parse(body("3", "{\"text\":5,\"lines\":[\"x\",\"y\"]}"), 10_000)
  let assert [exchange] = testing.exchanges(loaded)
  testing.request(exchange).body |> should.equal(<<"x\ny":utf8>>)
  cassette.parse(body("4", "{\"text\":\"\"}"), 10_000)
  |> should.equal(Error(cassette.UnsupportedVersion(4)))
}

// The layout, pinned byte for byte: one field per line, a header pair, a
// chunk or a body line on its own line, a failure on one line.
pub fn encoding_writes_the_schema_3_layout_test() {
  let assert Ok(req) = request.to("http://offline.invalid/ask?q=1")
  let first =
    testing.exchange(
      req
        |> request.set_header("accept", "text/plain")
        |> request.set_body(<<"line one\nline two\n":utf8>>),
      testing.Respond(
        response.Response(200, [#("content-type", "text/event-stream")], [
          <<"data: a\n\n":utf8>>,
          <<"ok":utf8>>,
        ]),
        testing.Finished([#("x-end", "yes")]),
      ),
    )
  let second =
    testing.exchange(
      request.set_body(req, <<>>),
      testing.Respond(response.Response(204, [], []), testing.Finished([])),
    )
  cassette.encode(testing.script([first, second]))
  |> should.equal(
    "{
  \"http_gun\": 3,
  \"exchanges\": [
    {
      \"request\": {
        \"method\": \"GET\",
        \"url\": \"http://offline.invalid/ask?q=1\",
        \"headers\": [
          [\"accept\", \"text/plain\"]
        ],
        \"body\": {\"lines\": [
          \"line one\",
          \"line two\",
          \"\"
        ]}
      },
      \"reply\": {
        \"kind\": \"response\",
        \"status\": 200,
        \"headers\": [
          [\"content-type\", \"text/event-stream\"]
        ],
        \"chunks\": [
          {\"lines\": [
            \"data: a\",
            \"\",
            \"\"
          ]},
          {\"text\": \"ok\"}
        ],
        \"ending\": {\"kind\": \"finished\", \"trailers\": [
          [\"x-end\", \"yes\"]
        ]}
      }
    },
    {
      \"request\": {
        \"method\": \"GET\",
        \"url\": \"http://offline.invalid/ask?q=1\",
        \"headers\": [],
        \"body\": {\"text\": \"\"}
      },
      \"reply\": {
        \"kind\": \"response\",
        \"status\": 204,
        \"headers\": [],
        \"chunks\": [],
        \"ending\": {\"kind\": \"finished\", \"trailers\": []}
      }
    }
  ]
}
",
  )
  cassette.encode(testing.script([]))
  |> should.equal("{\n  \"http_gun\": 3,\n  \"exchanges\": []\n}\n")
}

pub fn upgrade_keeps_bodies_the_default_redaction_would_change_test() {
  // A schema 2 file recorded before field redaction: a JSON answer with a
  // credential-named field, split over two chunks, and a truncated JSON
  // answer. Encoding would rewrite both; upgrading keeps every byte.
  let schema_2 =
    "{\"http_gun\":2,\"exchanges\":[{\"request\":{\"method\":\"GET\",\"url\":\"http://offline.invalid/ask\",\"headers\":[],\"body\":{\"text\":\"\"}},\"reply\":{\"kind\":\"response\",\"status\":200,\"headers\":[[\"content-type\",\"application/json\"]],\"chunks\":[{\"text\":\"{\\\"token\\\":\"},{\"text\":\"\\\"t-1\\\"}\"}],\"ending\":{\"kind\":\"finished\",\"trailers\":[]}}},{\"request\":{\"method\":\"GET\",\"url\":\"http://offline.invalid/ask\",\"headers\":[],\"body\":{\"text\":\"\"}},\"reply\":{\"kind\":\"response\",\"status\":200,\"headers\":[[\"content-type\",\"application/json\"]],\"chunks\":[{\"text\":\"{\\\"partial\\\":\"}],\"ending\":{\"kind\":\"abandoned\"}}}]}"
  let assert Ok(original) = cassette.parse(schema_2, 100_000)
  let assert Ok(upgraded) = cassette.upgrade(schema_2, 100_000)
  string.contains(upgraded, "\"http_gun\": 3") |> should.be_true
  let assert Ok(reloaded) = cassette.parse(upgraded, 100_000)
  testing.exchanges(reloaded) |> should.equal(testing.exchanges(original))
  // Encoding, by contrast, applies the default redaction.
  let assert Ok(encoded) = cassette.parse(cassette.encode(original), 100_000)
  { testing.exchanges(encoded) == testing.exchanges(original) }
  |> should.be_false

  // Upgrading is idempotent, and fails as parsing fails.
  cassette.upgrade(upgraded, 100_000) |> should.equal(Ok(upgraded))
  cassette.upgrade(schema_2, 10)
  |> should.equal(Error(cassette.TooLarge(10, string.byte_size(schema_2))))
  cassette.upgrade("not JSON", 100) |> should.equal(Error(cassette.Corrupt))
}
