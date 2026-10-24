import http_gun/error.{type Failure}

pub type Observation {
  Head(status: Int, headers: List(#(String, String)))
  Bytes(BitArray)
  Complete(trailers: List(#(String, String)))
  Failed(Failure)
}
