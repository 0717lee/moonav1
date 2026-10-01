///|
priv struct Av1IvfStreamState {
  limits : DecodeLimits
  mut track : Av1DemuxedTrack?
  mut scale : Int64
  mut declared : Int64
  mut count : Int
}

///|
fn Av1IvfStreamState::new(limits : DecodeLimits) -> Av1IvfStreamState {
  { limits, track: None, scale: 0L, declared: 0L, count: 0, }
}

///|
fn Av1IvfStreamState::retained_bytes(_self : Av1IvfStreamState) -> Int {
  0
}

///|
fn Av1IvfStreamState::step(
  self : Av1IvfStreamState,
  input : ContainerStreamInput,
  eof : Bool,
) -> Result[ContainerStreamStep, DecodeError] {
  let p = input.start
  let data = input.bytes
  let available = input.available()
  if self.track is None {
    if available < 32 {
      return Ok(Wait)
    }
    let size = ivf_u16(data, p + 6)
    if size < 32 {
      return Err(decode_error(InvalidData, "ivf.header", "Invalid header size"))
    }
    if size > self.limits.max_input_bytes {
      return Err(
        decode_error(
          LimitExceeded,
          "ivf.header",
          "Header exceeds retained-input budget",
        ),
      )
    }
    if available < size {
      return Ok(Wait)
    }
    let header = Array::makei(size, i => data[p + i])
    self.declared = ivf_u32(header, 24)
    if self.declared > self.limits.max_frames.to_int64() {
      return Err(
        decode_error(LimitExceeded, "ivf.header", "Track exceeds max_frames"),
      )
    }
    // Reuse the complete parser's exact header checks, with unspecified count.
    for i in 24..<28 {
      header[i] = 0
    }
    self.track = Some(
      match av1_demux_ivf(header, limits=self.limits) {
        Err(error) => return Err(error)
        Ok(value) => value
      },
    )
    self.scale = ivf_u32(data, p + 20)
    input.consume(size)
    return Ok(Progress)
  }
  if available == 0 && eof {
    if self.declared != 0L && self.declared != self.count.to_int64() {
      return Err(
        decode_error(
          TruncatedInput,
          "ivf.count",
          "Declared record count exceeds available packets",
        ),
      )
    }
    return Ok(End)
  }
  if available < 12 {
    return Ok(Wait)
  }
  if self.count == self.limits.max_frames ||
    (self.declared != 0L && self.count.to_int64() == self.declared) {
    let kind = if self.count == self.limits.max_frames {
      LimitExceeded
    } else {
      InvalidData
    }
    return Err(decode_error(kind, "ivf.count", "Too many IVF records"))
  }
  let length = ivf_u32(data, p)
  if length == 0L {
    return Err(decode_error(InvalidData, "ivf.packet", "Empty AV1 record"))
  }
  if self.limits.max_input_bytes < 12 ||
    length > (self.limits.max_input_bytes - 12).to_int64() {
    return Err(
      decode_error(
        LimitExceeded,
        "ivf.packet",
        "Record exceeds retained-input budget",
      ),
    )
  }
  if length > (available - 12).to_int64() {
    return Ok(Wait)
  }
  let timestamp = ivf_timestamp(data, p + 4)
  if timestamp > 9223372036854775807L / self.scale ||
    timestamp < (-9223372036854775807L - 1L) / self.scale {
    return Err(
      decode_error(
        Unsupported,
        "ivf.timestamp",
        "Scaled timestamp does not fit Int64",
      ),
    )
  }
  let packet : Av1Packet = {
    data: Array::makei(length.to_int(), i => data[p + 12 + i]),
    presentation_timestamp: Some(timestamp * self.scale),
    decode_timestamp: None,
    duration: None,
    sync_sample: None,
  }
  input.consume(12 + length.to_int())
  self.count += 1
  Ok(Packet(packet))
}
