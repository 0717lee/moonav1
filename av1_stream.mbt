///|
pub(all) enum Av1StreamStatus {
  NeedMoreInput
  FramesReady
  Finished
} derive(Eq, Debug)

///|
/// Every picture owns its buffers. Always consume frames, including when
/// status is Finished. FramesReady may coexist with a pending partial unit.
pub struct Av1StreamBatch {
  frames : Array[Av1NativeFrame]
  status : Av1StreamStatus
}

///|
/// Low-overhead AV1 byte-stream adapter. Temporal delimiters close units;
/// finish() or end_temporal_unit() closes an externally delimited final unit.
/// No network/file IO is performed. A failure is sticky until reset().
pub struct Av1StreamDecoder {
  priv mut decoder : Av1VideoDecoder
  priv limits : DecodeLimits
  priv allow_monochrome : Bool
  priv mut bytes : Array[Byte]
  priv mut scanned : Int
  priv mut content : Bool
  priv mut base_offset : Int64
  priv mut finished : Bool
  priv mut failure : DecodeError?
}

///|
pub fn Av1StreamDecoder::new(
  limits? : DecodeLimits = DecodeLimits::default(),
  allow_monochrome? : Bool = false,
) -> Result[Av1StreamDecoder, DecodeError] {
  match decode_checked_budget(0, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok({
    decoder: av1_video_decoder(),
    limits,
    allow_monochrome,
    bytes: [],
    scanned: 0,
    content: false,
    base_offset: 0L,
    finished: false,
    failure: None,
  })
}

///|
pub fn Av1StreamDecoder::reset(self : Av1StreamDecoder) -> Unit {
  self.decoder = av1_video_decoder()
  self.bytes = []
  self.scanned = 0
  self.content = false
  self.base_offset = 0L
  self.finished = false
  self.failure = None
}

///|
/// Retained compressed bytes, including at most sixteen lookahead header bytes.
pub fn Av1StreamDecoder::pending_bytes(self : Av1StreamDecoder) -> Int {
  self.bytes.length()
}

///|
fn Av1StreamDecoder::stream_absolute_error(
  self : Av1StreamDecoder,
  error : DecodeError,
  start : Int,
) -> DecodeError {
  {
    ..error,
    byte_offset: error.byte_offset.map(at => {
      self.base_offset + start.to_int64() + at
    }),
  }
}

///|
fn Av1StreamDecoder::stream_emit(
  self : Av1StreamDecoder,
  start : Int,
  end : Int,
  budget : DecodeBudget,
  output : Array[Av1NativeFrame],
) -> Result[Unit, DecodeError] {
  let unit = Array::makei(end - start, i => self.bytes[start + i])
  match
    av1_decode_checked_planes(self.decoder, unit, self.allow_monochrome, budget) {
    Err(error) => Err(self.stream_absolute_error(error, start))
    Ok(frames) => {
      for frame in frames {
        output.push(av1_frame_to_native(frame))
      }
      Ok(())
    }
  }
}

///|
fn Av1StreamDecoder::stream_drain(
  self : Av1StreamDecoder,
  eof : Bool,
  budget : DecodeBudget,
  output : Array[Av1NativeFrame],
) -> Result[Unit, DecodeError] {
  let mut start = 0
  while self.scanned < self.bytes.length() {
    let span = match
      av1_read_obu_span(
        self.bytes,
        self.scanned,
        eof,
        self.limits.max_input_bytes,
      ) {
      Err(error) => return Err(self.stream_absolute_error(error, 0))
      Ok(None) => break
      Ok(Some(value)) => value
    }
    if span.kind == 2 {
      if span.end != span.payload_offset {
        return Err(
          self.stream_absolute_error(
            decode_error(
              InvalidData,
              "stream",
              "Temporal delimiter payload must be empty",
              offset=Some(span.offset),
            ),
            0,
          ),
        )
      }
      if self.content {
        match self.stream_emit(start, span.offset, budget, output) {
          Err(error) => return Err(error)
          Ok(_) => ()
        }
      }
      start = span.offset
      self.content = false
    } else {
      self.content = true
      if span.end - start > self.limits.max_input_bytes {
        return Err(
          self.stream_absolute_error(
            decode_error(
              LimitExceeded,
              "stream",
              "Temporal unit exceeds max_input_bytes",
              offset=Some(start),
            ),
            0,
          ),
        )
      }
    }
    self.scanned = span.end
  }
  if eof {
    if self.content {
      match self.stream_emit(start, self.bytes.length(), budget, output) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
    }
    start = self.bytes.length()
    self.content = false
  }
  // Compact once per drain, rather than copying the trailing input per frame.
  // Incomplete single-byte feeds append in place and never copy the whole TU.
  if start > 0 {
    self.bytes = Array::makei(self.bytes.length() - start, i => {
      self.bytes[start + i]
    })
    self.scanned -= start
    self.base_offset += start.to_int64()
  }
  Ok(())
}

///|
/// max_input_bytes caps each supplied chunk and complete temporal unit. The
/// retained buffer allows sixteen extra bytes to recognize the next delimiter.
/// Picture/pixel budgets are shared by all units decoded during this call.
pub fn Av1StreamDecoder::feed(
  self : Av1StreamDecoder,
  chunk : Array[Byte],
) -> Result[Av1StreamBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.finished {
    return Err(
      decode_error(
        InvalidState,
        "stream",
        "Stream is finished; reset before feeding again",
      ),
    )
  }
  let budget = match decode_checked_budget(chunk.length(), self.limits) {
    Err(error) => {
      self.failure = Some(error)
      return Err(error)
    }
    Ok(value) => value
  }
  let output : Array[Av1NativeFrame] = []
  let capacity = if self.limits.max_input_bytes > 0x7FFFFFFF - 16 {
    0x7FFFFFFF
  } else {
    self.limits.max_input_bytes + 16
  }
  let mut position = 0
  while position < chunk.length() {
    let available = capacity - self.bytes.length()
    if available <= 0 {
      let error = {
        ..decode_error(
          LimitExceeded,
          "stream",
          "Pending temporal unit exceeds the retained-input budget",
        ),
        byte_offset: Some(self.base_offset),
      }
      self.failure = Some(error)
      return Err(error)
    }
    let count = if chunk.length() - position < available {
      chunk.length() - position
    } else {
      available
    }
    for i in position..<(position + count) {
      self.bytes.push(chunk[i])
    }
    position += count
    match self.stream_drain(false, budget, output) {
      Err(error) => {
        self.failure = Some(error)
        return Err(error)
      }
      Ok(_) => ()
    }
  }
  Ok({
    status: if output.is_empty() {
      NeedMoreInput
    } else {
      FramesReady
    },
    frames: output,
  })
}

///|
/// Explicit sample/TU boundary for inputs whose transport supplies framing
/// instead of temporal-delimiter OBUs. References survive between samples.
pub fn Av1StreamDecoder::end_temporal_unit(
  self : Av1StreamDecoder,
) -> Result[Av1StreamBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.finished {
    return Err(
      decode_error(InvalidState, "stream", "Stream is already finished"),
    )
  }
  let budget = match decode_checked_budget(0, self.limits) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let output : Array[Av1NativeFrame] = []
  match self.stream_drain(true, budget, output) {
    Err(error) => {
      self.failure = Some(error)
      Err(error)
    }
    Ok(_) =>
      Ok({
        status: if output.is_empty() {
          NeedMoreInput
        } else {
          FramesReady
        },
        frames: output,
      })
  }
}

///|
/// Complete the input, rejecting truncated final OBUs. Idempotent after success.
pub fn Av1StreamDecoder::finish(
  self : Av1StreamDecoder,
) -> Result[Av1StreamBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.finished {
    return Ok({ frames: [], status: Finished, })
  }
  match self.end_temporal_unit() {
    Err(error) => Err(error)
    Ok(batch) => {
      self.finished = true
      Ok({ ..batch, status: Finished, })
    }
  }
}
