///|
priv struct Av1ObuSpan {
  offset : Int
  payload_offset : Int
  end : Int
  kind : Int
  extension : Bool
  temporal_id : Int
  spatial_id : Int
}

///|
/// None means incomplete input only when eof=false. Unsized terminal OBUs need
/// EOF. The byte-stream adapter and complete-buffer diagnostic API share this.
fn av1_read_obu_span(
  data : Array[Byte],
  start : Int,
  eof : Bool,
  limit : Int,
) -> Result[Av1ObuSpan?, DecodeError] {
  let short = fn(at : Int) -> Result[Av1ObuSpan?, DecodeError] {
    if eof {
      Err(
        decode_error(
          TruncatedInput,
          "obu",
          "Incomplete OBU header or payload",
          offset=Some(at),
        ),
      )
    } else {
      Ok(None)
    }
  }
  if start < 0 || start >= data.length() {
    return short(start)
  }
  let header = data[start].to_int()
  if (header & 0x81) != 0 {
    return Err(
      decode_error(
        InvalidData,
        "obu",
        "Forbidden or reserved OBU header bit",
        offset=Some(start),
      ),
    )
  }
  let mut pos = start + 1
  let extension = (header & 4) != 0
  let mut temporal_id = 0
  let mut spatial_id = 0
  if extension {
    if pos == data.length() {
      return short(pos)
    }
    let ext = data[pos].to_int()
    if (ext & 7) != 0 {
      return Err(
        decode_error(
          InvalidData,
          "obu",
          "Reserved OBU extension bits",
          offset=Some(pos),
        ),
      )
    }
    temporal_id = ext >> 5
    spatial_id = (ext >> 3) & 3
    pos += 1
  }
  let mut length = 0
  if (header & 2) == 0 {
    if !eof {
      return Ok(None)
    }
    length = data.length() - pos
  } else {
    let length_offset = pos
    let mut terminated = false
    for i in 0..<8 {
      if pos == data.length() {
        return short(pos)
      }
      let byte = data[pos].to_int()
      pos += 1
      let part = byte & 127
      if (i == 4 && part > 7) || (i > 4 && part != 0) {
        return Err(
          decode_error(
            LimitExceeded,
            "obu",
            "OBU length exceeds the supported input size",
            offset=Some(length_offset),
          ),
        )
      }
      if i <= 4 {
        length = length | (part << (i * 7))
      }
      if (byte & 128) == 0 {
        terminated = true
        break
      }
    }
    if !terminated {
      return Err(
        decode_error(
          InvalidData,
          "obu",
          "OBU length exceeds eight leb128 bytes",
          offset=Some(length_offset),
        ),
      )
    }
  }
  if length > limit || pos - start > limit - length {
    return Err(
      decode_error(
        LimitExceeded,
        "obu",
        "Declared OBU exceeds the input budget",
        offset=Some(start),
      ),
    )
  }
  if length > data.length() - pos {
    return short(data.length())
  }
  Ok(
    Some({
      offset: start,
      payload_offset: pos,
      end: pos + length,
      kind: (header >> 3) & 15,
      extension,
      temporal_id,
      spatial_id,
    }),
  )
}

///|
fn av1_obu_packets_checked(
  data : Array[Byte],
  limit? : Int = 0x7FFFFFFF,
) -> Result[Array[Av1ObuPacket], DecodeError] {
  let packets : Array[Av1ObuPacket] = []
  let mut pos = 0
  while pos < data.length() {
    let span = match av1_read_obu_span(data, pos, true, limit) {
      Ok(Some(value)) => value
      Err(error) => return Err(error)
      Ok(None) =>
        return Err(
          decode_error(
            TruncatedInput,
            "obu",
            "Incomplete OBU",
            offset=Some(pos),
          ),
        )
    }
    packets.push({
      kind: span.kind,
      extension: span.extension,
      temporal_id: span.temporal_id,
      spatial_id: span.spatial_id,
      offset: span.offset,
      payload_offset: span.payload_offset,
      payload: Array::makei(span.end - span.payload_offset, i => {
        data[span.payload_offset + i]
      }),
    })
    pos = span.end
  }
  Ok(packets)
}
