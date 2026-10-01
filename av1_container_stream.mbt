///|
pub(all) enum Av1ContainerStreamStatus {
  NeedMoreInput
  Ready
  ReplayRequired
  Finished
} derive(Eq, Debug)

///|
/// Owned metadata for the selected track. Packet payloads are delivered only
/// in batches and are not retained in this value.
pub struct Av1ContainerStreamInfo {
  format : Av1ContainerFormat
  track_id : Int64
  width : Int
  height : Int
  timescale : Int64
  movie_timescale : Int64?
  edits : Array[Av1TrackEdit]
  codec_initialization : Array[Byte]
}

///|
pub struct Av1ContainerPacketBatch {
  packets : Array[Av1Packet]
  status : Av1ContainerStreamStatus
}

///|
priv struct ContainerStreamInput {
  mut bytes : Array[Byte]
  mut start : Int
  mut base_offset : Int64
}

///|
fn ContainerStreamInput::available(self : ContainerStreamInput) -> Int {
  self.bytes.length() - self.start
}

///|
fn ContainerStreamInput::offset(self : ContainerStreamInput) -> Int64 {
  self.base_offset + self.start.to_int64()
}

///|
fn ContainerStreamInput::consume(
  self : ContainerStreamInput,
  count : Int,
) -> Unit {
  self.start += count
}

///|
fn ContainerStreamInput::compact(self : ContainerStreamInput) -> Unit {
  if self.start != 0 {
    let start = self.start
    self.bytes = Array::makei(self.bytes.length() - start, i => {
      self.bytes[start + i]
    })
    self.base_offset += start.to_int64()
    self.start = 0
  }
}

///|
priv enum ContainerStreamStep {
  Wait
  // Consumes input. Non-consuming phase transitions stay inside step().
  Progress
  // Consumes input or removes an owned packet from a bounded backend queue.
  Packet(Av1Packet)
  End
  ReplayRequired
}

///|
priv enum ContainerStreamBackend {
  Ivf(Av1IvfStreamState)
  Mp4(Av1Mp4StreamState)
  WebM(Av1WebmStreamState)
}

///|
/// Incremental container demux. max_input_bytes bounds retained compressed
/// input/metadata and each feed; max_frames bounds the selected track's total
/// packet count. A whole file may exceed max_input_bytes. Expanded sample
/// tables are additionally bounded by max_frames. No file or network IO occurs.
pub struct Av1ContainerStream {
  priv format_hint : Av1ContainerFormat?
  priv track_id : Int64?
  priv limits : DecodeLimits
  priv input : ContainerStreamInput
  priv mut backend : ContainerStreamBackend?
  priv mut packet_count : Int
  priv mut peak_pending : Int
  priv mut received : Int64
  priv mut terminal : Av1ContainerStreamStatus?
  priv mut failure : DecodeError?
}

///|
pub fn Av1ContainerStream::new(
  format? : Av1ContainerFormat? = None,
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1ContainerStream, DecodeError] {
  match decode_checked_budget(0, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  Ok({
    format_hint: format,
    track_id,
    limits,
    input: { bytes: [], start: 0, base_offset: 0L, },
    backend: None,
    packet_count: 0,
    peak_pending: 0,
    received: 0L,
    terminal: None,
    failure: None,
  })
}

///|
pub fn Av1ContainerStream::reset(self : Av1ContainerStream) -> Unit {
  self.input.bytes = []
  self.input.start = 0
  self.input.base_offset = 0L
  self.backend = None
  self.packet_count = 0
  self.peak_pending = 0
  self.received = 0L
  self.terminal = None
  self.failure = None
}

///|
fn Av1ContainerStream::metadata_bytes(self : Av1ContainerStream) -> Int {
  match self.backend {
    Some(Ivf(state)) => state.retained_bytes()
    Some(Mp4(state)) => state.retained_bytes()
    Some(WebM(state)) => state.retained_bytes()
    None => 0
  }
}

///|
pub fn Av1ContainerStream::pending_bytes(self : Av1ContainerStream) -> Int {
  let pending = self.input.available()
  let metadata = self.metadata_bytes()
  if metadata > 0x7FFFFFFF - pending {
    0x7FFFFFFF
  } else {
    pending + metadata
  }
}

///|
/// High-water mark since reset, including both passes of a tail-moov replay.
pub fn Av1ContainerStream::peak_pending_bytes(self : Av1ContainerStream) -> Int {
  self.peak_pending
}

///|
pub fn Av1ContainerStream::packet_count(self : Av1ContainerStream) -> Int {
  self.packet_count
}

///|
pub fn Av1ContainerStream::bytes_received(self : Av1ContainerStream) -> Int64 {
  self.received
}

///|
/// Copies variable-size metadata, so mutating a result cannot change parsing.
pub fn Av1ContainerStream::track_info(
  self : Av1ContainerStream,
) -> Av1ContainerStreamInfo? {
  let track = match self.backend {
    Some(Ivf(state)) => state.track
    Some(Mp4(state)) => state.track
    Some(WebM(state)) => state.track
    None => None
  }
  track.map(value => {
    format: value.format,
    track_id: value.track_id,
    width: value.width,
    height: value.height,
    timescale: value.timescale,
    movie_timescale: value.movie_timescale,
    edits: Array::makei(value.edits.length(), i => value.edits[i]),
    codec_initialization: Array::makei(value.codec_initialization.length(), i => {
      value.codec_initialization[i]
    }),
  })
}

///|
fn container_stream_sniff(
  input : ContainerStreamInput,
) -> Result[Av1ContainerFormat?, DecodeError] {
  if input.available() < 4 {
    return Ok(None)
  }
  let p = input.start
  let b = input.bytes
  if b[p] == b'D' && b[p + 1] == b'K' && b[p + 2] == b'I' && b[p + 3] == b'F' {
    return Ok(Some(Ivf))
  }
  if b[p] == 0x1A && b[p + 1] == 0x45 && b[p + 2] == 0xDF && b[p + 3] == 0xA3 {
    return Ok(Some(WebM))
  }
  if input.available() < 8 {
    return Ok(None)
  }
  let kind = (b[p + 4].to_int() << 24) |
    (b[p + 5].to_int() << 16) |
    (b[p + 6].to_int() << 8) |
    b[p + 7].to_int()
  match kind {
    0x66747970
    | 0x73747970
    | 0x6D6F6F76
    | 0x6D6F6F66
    | 0x6D646174
    | 0x66726565
    | 0x736B6970
    | 0x77696465
    | 0x75756964 => Ok(Some(Mp4))
    _ =>
      Err(
        decode_error(
          Unsupported,
          "container.stream",
          "Unrecognized video container",
        ),
      )
  }
}

///|
fn Av1ContainerStream::drain(
  self : Av1ContainerStream,
  eof : Bool,
  output : Array[Av1Packet],
) -> Result[Unit, DecodeError] {
  if self.backend is None {
    let format = match self.format_hint {
      Some(value) => Some(value)
      None =>
        match container_stream_sniff(self.input) {
          Err(error) => return Err(error)
          Ok(value) => value
        }
    }
    match format {
      None => {
        if eof {
          return Err(
            decode_error(
              TruncatedInput,
              "container.stream",
              "Incomplete container signature",
            ),
          )
        }
        return Ok(())
      }
      Some(Ivf) => {
        if self.track_id is Some(id) && id != 0L {
          return Err(
            decode_error(InvalidData, "ivf.track", "IVF has only track zero"),
          )
        }
        self.backend = Some(Ivf(Av1IvfStreamState::new(self.limits)))
      }
      Some(Mp4) =>
        self.backend = Some(
          Mp4(Av1Mp4StreamState::new(self.track_id, self.limits)),
        )
      Some(WebM) =>
        self.backend = Some(
          WebM(Av1WebmStreamState::new(self.track_id, self.limits)),
        )
    }
  }
  while true {
    let before = self.input.offset()
    let step = match self.backend {
      Some(Ivf(state)) => state.step(self.input, eof)
      Some(Mp4(state)) => state.step(self.input, eof)
      Some(WebM(state)) => state.step(self.input, eof)
      None =>
        return Err(
          decode_error(InvalidState, "container.stream", "Missing format state"),
        )
    }
    let step = match step {
      Err(error) => return Err(error)
      Ok(value) => value
    }
    let metadata = self.metadata_bytes()
    if metadata < 0 ||
      metadata > self.limits.max_input_bytes - self.input.available() {
      return Err(
        decode_error(
          LimitExceeded,
          "container.stream",
          "Retained compressed data exceeds max_input_bytes",
        ),
      )
    }
    let held = self.pending_bytes()
    if held > self.peak_pending {
      self.peak_pending = held
    }
    match step {
      Wait => {
        if eof {
          return Err(
            decode_error(
              TruncatedInput,
              "container.stream",
              "Incomplete final container unit",
            ),
          )
        }
        break
      }
      Progress =>
        if self.input.offset() == before {
          return Err(
            decode_error(
              InvalidState,
              "container.stream",
              "Parser made no progress",
            ),
          )
        }
      Packet(packet) => {
        if packet.data.is_empty() {
          return Err(
            decode_error(InvalidData, "container.stream", "Empty AV1 sample"),
          )
        }
        if packet.data.length() > self.limits.max_input_bytes {
          return Err(
            decode_error(
              LimitExceeded,
              "container.stream",
              "Sample exceeds max_input_bytes",
            ),
          )
        }
        if self.packet_count == self.limits.max_frames {
          return Err(
            decode_error(
              LimitExceeded,
              "container.stream",
              "Packet count exceeds max_frames",
            ),
          )
        }
        self.packet_count += 1
        output.push(packet)
      }
      End => {
        self.terminal = Some(Finished)
        break
      }
      ReplayRequired => {
        self.terminal = Some(ReplayRequired)
        break
      }
    }
  }
  self.input.compact()
  Ok(())
}

///|
pub fn Av1ContainerStream::feed(
  self : Av1ContainerStream,
  chunk : Array[Byte],
) -> Result[Av1ContainerPacketBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.terminal is Some(_) {
    return Err(
      decode_error(
        InvalidState,
        "container.stream",
        "Stream is finished; reset or replay before feeding",
      ),
    )
  }
  let result = self.feed_inner(chunk)
  if result is Err(error) {
    self.failure = Some(error)
  }
  result
}

///|
fn Av1ContainerStream::feed_inner(
  self : Av1ContainerStream,
  chunk : Array[Byte],
) -> Result[Av1ContainerPacketBatch, DecodeError] {
  if chunk.length() > self.limits.max_input_bytes ||
    self.received > 9223372036854775807L - chunk.length().to_int64() {
    return Err(
      decode_error(
        LimitExceeded,
        "container.stream",
        "Input chunk or cumulative offset exceeds its limit",
      ),
    )
  }
  self.received += chunk.length().to_int64()
  let output : Array[Av1Packet] = []
  let mut at = 0
  while at < chunk.length() {
    let capacity = self.limits.max_input_bytes - self.pending_bytes()
    if capacity <= 0 {
      return Err(
        decode_error(
          LimitExceeded,
          "container.stream",
          "Container unit exceeds the retained-input budget",
        ),
      )
    }
    let count = if chunk.length() - at < capacity {
      chunk.length() - at
    } else {
      capacity
    }
    for i in at..<(at + count) {
      self.input.bytes.push(chunk[i])
    }
    at += count
    let held = self.pending_bytes()
    if held > self.peak_pending {
      self.peak_pending = held
    }
    match self.drain(false, output) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    if self.terminal is Some(_) && at < chunk.length() {
      return Err(
        decode_error(
          InvalidData,
          "container.stream",
          "Unexpected bytes after end of container",
        ),
      )
    }
  }
  Ok({
    packets: output,
    status: match self.terminal {
      Some(value) => value
      None => if output.is_empty() { NeedMoreInput } else { Ready }
    },
  })
}

///|
pub fn Av1ContainerStream::finish(
  self : Av1ContainerStream,
) -> Result[Av1ContainerPacketBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.terminal is Some(status) {
    return Ok({ packets: [], status, })
  }
  let packets : Array[Av1Packet] = []
  match self.drain(true, packets) {
    Err(error) => {
      self.failure = Some(error)
      Err(error)
    }
    Ok(_) => Ok({ packets, status: self.terminal.unwrap(), })
  }
}

///|
/// After an index-at-tail MP4 completes its metadata-only first pass, replay
/// the original file from byte zero using the retained index. No media bytes
/// from the first pass were retained or emitted.
pub fn Av1ContainerStream::replay(
  self : Av1ContainerStream,
) -> Result[Unit, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  if self.terminal != Some(ReplayRequired) {
    return Err(
      decode_error(
        InvalidState,
        "container.stream",
        "No completed replay request",
      ),
    )
  }
  let backend : ContainerStreamBackend = match self.backend {
    Some(Mp4(state)) =>
      match state.replay() {
        Err(error) => {
          self.failure = Some(error)
          return Err(error)
        }
        Ok(value) => Mp4(value)
      }
    _ =>
      return Err(
        decode_error(
          InvalidState,
          "container.stream",
          "Replay requires MP4 metadata",
        ),
      )
  }
  self.input.bytes = []
  self.input.start = 0
  self.input.base_offset = 0L
  self.backend = Some(backend)
  self.packet_count = 0
  self.received = 0L
  self.terminal = None
  Ok(())
}
