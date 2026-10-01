///|
pub struct Av1ContainerFrameBatch {
  frames : Array[Av1ContainerFrame]
  status : Av1ContainerStreamStatus
}

///|
/// Stateful native decoding over bounded container input. All pictures decoded
/// during one feed/finish share a reconstruction budget, including hidden ones.
pub struct Av1ContainerStreamDecoder {
  priv stream : Av1ContainerStream
  priv limits : DecodeLimits
  priv mut decoder : Av1VideoDecoder
  priv mut initialized : Bool
  priv mut packet_index : Int
  priv mut failure : DecodeError?
}

///|
pub fn Av1ContainerStreamDecoder::new(
  format? : Av1ContainerFormat? = None,
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1ContainerStreamDecoder, DecodeError] {
  let stream = match Av1ContainerStream::new(format~, track_id~, limits~) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  Ok({
    stream,
    limits,
    decoder: av1_video_decoder(),
    initialized: false,
    packet_index: 0,
    failure: None,
  })
}

///|
pub fn Av1ContainerStreamDecoder::reset(
  self : Av1ContainerStreamDecoder,
) -> Unit {
  self.stream.reset()
  self.decoder = av1_video_decoder()
  self.initialized = false
  self.packet_index = 0
  self.failure = None
}

///|
pub fn Av1ContainerStreamDecoder::replay(
  self : Av1ContainerStreamDecoder,
) -> Result[Unit, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  match self.stream.replay() {
    Err(error) => {
      // Lifecycle misuse leaves a healthy completed stream intact. A parser
      // failure while replaying requires reset, just like feed and finish.
      if error.kind != InvalidState {
        self.failure = Some(error)
      }
      Err(error)
    }
    Ok(_) => {
      self.decoder = av1_video_decoder()
      self.initialized = false
      self.packet_index = 0
      Ok(())
    }
  }
}

///|
pub fn Av1ContainerStreamDecoder::pending_bytes(
  self : Av1ContainerStreamDecoder,
) -> Int {
  self.stream.pending_bytes()
}

///|
pub fn Av1ContainerStreamDecoder::peak_pending_bytes(
  self : Av1ContainerStreamDecoder,
) -> Int {
  self.stream.peak_pending_bytes()
}

///|
pub fn Av1ContainerStreamDecoder::track_info(
  self : Av1ContainerStreamDecoder,
) -> Av1ContainerStreamInfo? {
  self.stream.track_info()
}

///|
fn Av1ContainerStreamDecoder::decode_batch(
  self : Av1ContainerStreamDecoder,
  batch : Av1ContainerPacketBatch,
) -> Result[Av1ContainerFrameBatch, DecodeError] {
  let budget = match decode_checked_budget(0, self.limits) {
    Err(error) => return Err(error)
    Ok(value) => value
  }
  let frames : Array[Av1ContainerFrame] = []
  if batch.packets.is_empty() {
    return Ok({ frames, status: batch.status, })
  }
  let info = match self.stream.track_info() {
    None =>
      return Err(
        decode_error(
          InvalidState,
          "container.stream",
          "Packets arrived before track metadata",
        ),
      )
    Some(value) => value
  }
  for packet in batch.packets {
    let prefix = if self.initialized { [] } else { info.codec_initialization }
    if prefix.length() > self.limits.max_input_bytes - packet.data.length() {
      return Err(
        decode_error(
          LimitExceeded,
          "container.stream.packet",
          "Initialization and sample exceed max_input_bytes",
        ),
      )
    }
    let data = if prefix.is_empty() {
      packet.data
    } else {
      Array::makei(prefix.length() + packet.data.length(), i => {
        if i < prefix.length() {
          prefix[i]
        } else {
          packet.data[i - prefix.length()]
        }
      })
    }
    let decoded = match
      av1_decode_checked_planes(self.decoder, data, true, budget) {
      Err(error) =>
        return Err({
          ..error,
          byte_offset: None,
          context: "container.stream.packet/" + error.context,
          message: "Packet \{self.packet_index}: \{error.message}",
        })
      Ok(value) => value
    }
    if decoded.length() > 1 {
      return Err(
        decode_error(
          InvalidData,
          "container.stream.presentation",
          "A sample contains multiple selected presentations",
        ),
      )
    }
    self.initialized = true
    if decoded.length() == 1 {
      frames.push({
        packet_index: self.packet_index,
        timestamp: packet.presentation_timestamp,
        duration: packet.duration,
        timescale: info.timescale,
        frame: av1_frame_to_native(decoded[0]),
      })
    }
    self.packet_index += 1
  }
  Ok({ frames, status: batch.status, })
}

///|
pub fn Av1ContainerStreamDecoder::feed(
  self : Av1ContainerStreamDecoder,
  chunk : Array[Byte],
) -> Result[Av1ContainerFrameBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  let result = match self.stream.feed(chunk) {
    // The parser retains its own failures. A terminal-state feed mistake
    // must leave ReplayRequired metadata available to replay().
    Err(error) => return Err(error)
    Ok(batch) => self.decode_batch(batch)
  }
  if result is Err(error) {
    self.failure = Some(error)
  }
  result
}

///|
pub fn Av1ContainerStreamDecoder::finish(
  self : Av1ContainerStreamDecoder,
) -> Result[Av1ContainerFrameBatch, DecodeError] {
  if self.failure is Some(error) {
    return Err(error)
  }
  let result = match self.stream.finish() {
    Err(error) => Err(error)
    Ok(batch) => self.decode_batch(batch)
  }
  if result is Err(error) {
    self.failure = Some(error)
  }
  result
}
