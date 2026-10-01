///|
fn ivf_u16(data : Array[Byte], pos : Int) -> Int {
  data[pos].to_int() | (data[pos + 1].to_int() << 8)
}

///|
fn ivf_u32(data : Array[Byte], pos : Int) -> Int64 {
  let mut value = 0L
  for i in 0..<4 {
    value = value | (data[pos + i].to_int().to_int64() << (i * 8))
  }
  value
}

///|
fn ivf_timestamp(data : Array[Byte], pos : Int) -> Int64 {
  let mut value = 0L
  for i in 0..<8 {
    value = value | (data[pos + i].to_int().to_int64() << (i * 8))
  }
  value
}

///|
/// Read AV01 IVF records. The header time base is scale/rate seconds;
/// timestamps become pts*scale ticks with timescale=rate, checked in Int64.
/// IVF carries neither DTS, duration nor sync flags, so those remain None.
/// A zero declared record count means unspecified; a nonzero count is checked.
pub fn av1_demux_ivf(
  data : Array[Byte],
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1DemuxedTrack, DecodeError] {
  match av1_demux_validate_input(data, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if data.length() < 32 {
    return Err(
      decode_error(TruncatedInput, "ivf.header", "Incomplete IVF header"),
    )
  }
  if data[0] != b'D' || data[1] != b'K' || data[2] != b'I' || data[3] != b'F' {
    return Err(
      decode_error(InvalidData, "ivf.header", "Missing DKIF signature"),
    )
  }
  if ivf_u16(data, 4) != 0 {
    return Err(
      decode_error(Unsupported, "ivf.header", "Unsupported IVF version"),
    )
  }
  let header_size = ivf_u16(data, 6)
  if header_size < 32 {
    return Err(decode_error(InvalidData, "ivf.header", "Invalid header size"))
  }
  if header_size > data.length() {
    return Err(
      decode_error(TruncatedInput, "ivf.header", "Truncated extended header"),
    )
  }
  if data[8] != b'A' || data[9] != b'V' || data[10] != b'0' || data[11] != b'1' {
    return Err(decode_error(Unsupported, "ivf.codec", "IVF stream is not AV1"))
  }
  let width = ivf_u16(data, 12)
  let height = ivf_u16(data, 14)
  let rate = ivf_u32(data, 16)
  let scale = ivf_u32(data, 20)
  let declared = ivf_u32(data, 24)
  if width == 0 || height == 0 || rate == 0L || scale == 0L {
    return Err(
      decode_error(InvalidData, "ivf.header", "Invalid dimensions or time base"),
    )
  }
  if width > limits.max_frame_pixels / height ||
    declared > limits.max_frames.to_int64() {
    return Err(
      decode_error(LimitExceeded, "ivf.header", "Track exceeds selected limits"),
    )
  }
  let packets : Array[Av1Packet] = []
  let mut pos = header_size
  while pos < data.length() {
    if packets.length() == limits.max_frames {
      return Err(
        decode_error(
          LimitExceeded,
          "ivf.packet",
          "Packet count exceeds max_frames",
        ),
      )
    }
    if data.length() - pos < 12 {
      return Err(
        decode_error(
          TruncatedInput,
          "ivf.packet",
          "Incomplete record header",
          offset=Some(pos),
        ),
      )
    }
    let length = ivf_u32(data, pos)
    let timestamp = ivf_timestamp(data, pos + 4)
    if length == 0L {
      return Err(
        decode_error(
          InvalidData,
          "ivf.packet",
          "Empty AV1 record",
          offset=Some(pos),
        ),
      )
    }
    if length > (data.length() - pos - 12).to_int64() {
      return Err(
        decode_error(
          TruncatedInput,
          "ivf.packet",
          "Record payload is truncated",
          offset=Some(pos),
        ),
      )
    }
    if timestamp > 9223372036854775807L / scale ||
      timestamp < (-9223372036854775807L - 1L) / scale {
      return Err(
        decode_error(
          Unsupported,
          "ivf.timestamp",
          "Scaled timestamp does not fit Int64",
          offset=Some(pos + 4),
        ),
      )
    }
    pos += 12
    let payload = Array::makei(length.to_int(), i => data[pos + i])
    packets.push({
      data: payload,
      presentation_timestamp: Some(timestamp * scale),
      decode_timestamp: None,
      duration: None,
      sync_sample: None,
    })
    pos += length.to_int()
  }
  if declared != 0L && declared != packets.length().to_int64() {
    let kind = if declared > packets.length().to_int64() {
      TruncatedInput
    } else {
      InvalidData
    }
    return Err(
      decode_error(
        kind, "ivf.count", "Declared and actual record counts differ",
      ),
    )
  }
  Ok({
    format: Ivf,
    track_id: 0L,
    width,
    height,
    timescale: rate,
    movie_timescale: None,
    edits: [],
    codec_initialization: [],
    packets,
  })
}
