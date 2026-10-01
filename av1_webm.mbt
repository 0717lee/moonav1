///|
/// Pure MoonBit Matroska/WebM demux for AV1 low-overhead temporal units.
///
/// The parser deliberately keeps the container layer small: it understands
/// EBML element framing, the WebM/Matroska timing model, and the V_AV1 block
/// binding, while leaving OBU validation and decoder state to the AV1 code.
const WEBM_EBML : Int64 = 0x1A45DFA3L

///|
const WEBM_SEGMENT : Int64 = 0x18538067L

///|
const WEBM_INFO : Int64 = 0x1549A966L

///|
const WEBM_TIMECODE_SCALE : Int64 = 0x2AD7B1L

///|
const WEBM_TRACKS : Int64 = 0x1654AE6BL

///|
const WEBM_TRACK_ENTRY : Int64 = 0xAEL

///|
const WEBM_TRACK_NUMBER : Int64 = 0xD7L

///|
const WEBM_TRACK_TYPE : Int64 = 0x83L

///|
const WEBM_FLAG_LACING : Int64 = 0x9CL

///|
const WEBM_CODEC_ID : Int64 = 0x86L

///|
const WEBM_CODEC_PRIVATE : Int64 = 0x63A2L

///|
const WEBM_CODEC_DELAY : Int64 = 0x56AAL

///|
const WEBM_DEFAULT_DURATION : Int64 = 0x23E383L

///|
const WEBM_TRACK_TIMESTAMP_SCALE : Int64 = 0x23314FL

///|
const WEBM_CONTENT_ENCODINGS : Int64 = 0x6D80L

///|
const WEBM_VIDEO : Int64 = 0xE0L

///|
const WEBM_PIXEL_WIDTH : Int64 = 0xB0L

///|
const WEBM_PIXEL_HEIGHT : Int64 = 0xBAL

///|
const WEBM_CLUSTER : Int64 = 0x1F43B675L

///|
const WEBM_CLUSTER_TIMESTAMP : Int64 = 0xE7L

///|
const WEBM_SIMPLE_BLOCK : Int64 = 0xA3L

///|
const WEBM_BLOCK_GROUP : Int64 = 0xA0L

///|
const WEBM_BLOCK : Int64 = 0xA1L

///|
const WEBM_BLOCK_DURATION : Int64 = 0x9BL

///|
const WEBM_REFERENCE_BLOCK : Int64 = 0xFBL

///|
const WEBM_CODEC_STATE : Int64 = 0xA4L

///|
const WEBM_DISCARD_PADDING : Int64 = 0x75A2L

///|
const WEBM_BLOCK_ADDITIONS : Int64 = 0x75A1L

///|
const WEBM_VOID : Int64 = 0xECL

///|
const WEBM_CRC32 : Int64 = 0xBFL

///|
const WEBM_EBML_VERSION : Int64 = 0x4286L

///|
const WEBM_EBML_READ_VERSION : Int64 = 0x42F7L

///|
const WEBM_EBML_MAX_ID_LENGTH : Int64 = 0x42F2L

///|
const WEBM_EBML_MAX_SIZE_LENGTH : Int64 = 0x42F3L

///|
const WEBM_DOCTYPE_VERSION : Int64 = 0x4287L

///|
const WEBM_DOCTYPE_READ_VERSION : Int64 = 0x4285L

///|
const WEBM_NANOS : Int64 = 1000000000L

///|
const WEBM_DEFAULT_TIMESTAMP_SCALE : Int64 = 1000000L

///|
const WEBM_I64_MAX : Int64 = 9223372036854775807L

///|
const WEBM_I64_MIN : Int64 = -9223372036854775807L - 1L

///|
const WEBM_MAX_NESTING : Int = 64

///|
const WEBM_MAX_ELEMENTS : Int = 65536

///|
const WEBM_MAX_TRACKS : Int = 1024

///|
priv struct WebmVint {
  value : Int64
  width : Int
  unknown : Bool
}

///|
priv struct WebmElement {
  id : Int64
  start : Int
  payload : Int
  end : Int
  unknown : Bool
}

///|
priv struct WebmTrack {
  number : Int64
  track_type : Int
  codec_av1 : Bool
  codec_private : Array[Byte]?
  width : Int
  height : Int
  default_duration : Int64?
  codec_delay : Int64?
  flag_lacing : Bool
  content_encoded : Bool
  track_timestamp_scale_one : Bool
}

///|
priv struct WebmFrameSpan {
  start : Int
  end : Int
}

///|
priv struct WebmBlock {
  timecode : Int64
  frames : Array[WebmFrameSpan]
  keyframe : Bool
}

///|
priv struct WebmRawPacket {
  frame : WebmFrameSpan
  track_ticks : Int64
  duration_ticks : Int64?
  laced_index : Int
  laced_count : Int
  keyframe : Bool
  reference : Bool
}

///|
fn webm_error(
  kind : DecodeErrorKind,
  context : String,
  message : String,
  offset : Int,
) -> DecodeError {
  decode_error(kind, context, message, offset=Some(offset))
}

///|
fn webm_vint_width(first : Int) -> Int {
  let mut mask = 0x80
  let mut width = 1
  while width <= 8 && (first & mask) == 0 {
    mask = mask >> 1
    width += 1
  }
  if width > 8 {
    0
  } else {
    width
  }
}

///|
/// Read one EBML VINT. IDs retain the leading marker bit; sizes remove it.
/// Unknown sizes are represented by all payload bits set to one.
fn webm_read_vint(
  data : Array[Byte],
  at : Int,
  end : Int,
  id? : Bool = false,
  size_mode? : Bool = false,
) -> Result[WebmVint, DecodeError] {
  if at < 0 || at >= end || at >= data.length() {
    return Err(webm_error(TruncatedInput, "ebml/vint", "Missing VINT", at))
  }
  let first = data[at].to_int()
  let width = webm_vint_width(first)
  if width == 0 {
    return Err(
      webm_error(InvalidData, "ebml/vint", "VINT marker is missing", at),
    )
  }
  if width > end - at || width > data.length() - at {
    return Err(webm_error(TruncatedInput, "ebml/vint", "Truncated VINT", at))
  }
  if id && width > 4 {
    return Err(
      webm_error(InvalidData, "ebml/id", "EBML IDs are at most four octets", at),
    )
  }
  let marker = (1 << (8 - width)).to_int64()
  let marker_int = marker.to_int()
  let payload_bits = first & (marker_int - 1)
  let first_value = if id { first.to_int64() } else { payload_bits.to_int64() }
  let mut all_ones = size_mode && !id && first_value == marker - 1
  let mut id_all_zero = id && payload_bits == 0
  let mut id_all_ones = id && payload_bits == marker_int - 1
  for i in 1..<width {
    let byte = data[at + i].to_int()
    if !id && byte != 0xFF {
      all_ones = false
    }
    if id && byte != 0xFF {
      id_all_ones = false
    }
    if id && byte != 0 {
      id_all_zero = false
    }
  }
  if all_ones {
    return Ok({ value: 0, width, unknown: true, })
  }
  if id_all_ones {
    return Err(
      webm_error(InvalidData, "ebml/id", "All-one EBML ID is reserved", at),
    )
  }
  if id_all_zero && !(width == 1 && first == 0x80) {
    return Err(
      webm_error(
        InvalidData,
        "ebml/id",
        "All-zero EBML ID data is reserved",
        at,
      ),
    )
  }
  let mut value = first_value
  for i in 1..<width {
    let byte = data[at + i].to_int().to_int64()
    value = value * 256L + byte
  }
  if id && value == 0L {
    return Err(webm_error(InvalidData, "ebml/id", "Zero is not an EBML ID", at))
  }
  Ok({ value, width, unknown: false, })
}

///|
fn webm_read_element(
  data : Array[Byte],
  at : Int,
  parent_end : Int,
) -> Result[WebmElement, DecodeError] {
  let id = match webm_read_vint(data, at, parent_end, id=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let size_at = at + id.width
  let size = match webm_read_vint(data, size_at, parent_end, size_mode=true) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let payload = size_at + size.width
  if payload > parent_end || payload > data.length() {
    return Err(
      webm_error(
        TruncatedInput,
        "ebml/element",
        "Element header exceeds parent",
        at,
      ),
    )
  }
  let element_end = if size.unknown {
    parent_end
  } else if size.value > (parent_end - payload).to_int64() {
    return Err(
      webm_error(TruncatedInput, "ebml/element", "Element exceeds parent", at),
    )
  } else {
    payload + size.value.to_int()
  }
  Ok({
    id: id.value,
    start: at,
    payload,
    end: element_end,
    unknown: size.unknown,
  })
}

///|
fn webm_copy(data : Array[Byte], start : Int, end : Int) -> Array[Byte] {
  Array::makei(end - start, i => data[start + i])
}

///|
fn webm_uint(
  data : Array[Byte],
  start : Int,
  end : Int,
) -> Result[Int64, DecodeError] {
  if start > end || end > data.length() || end - start > 8 {
    return Err(
      webm_error(
        InvalidData,
        "webm/uint",
        "Invalid unsigned integer width",
        start,
      ),
    )
  }
  if start == end {
    return Err(
      webm_error(InvalidData, "webm/uint", "Empty unsigned integer", start),
    )
  }
  let mut value = 0L
  for i in start..<end {
    let byte = data[i].to_int().to_int64()
    if value > (WEBM_I64_MAX - byte) / 256L {
      return Err(
        webm_error(
          LimitExceeded,
          "webm/uint",
          "Unsigned integer overflows Int64",
          i,
        ),
      )
    }
    value = value * 256L + byte
  }
  Ok(value)
}

///|
fn webm_i64_add(a : Int64, b : Int64, at : Int) -> Result[Int64, DecodeError] {
  if (b > 0L && a > WEBM_I64_MAX - b) || (b < 0L && a < WEBM_I64_MIN - b) {
    Err(webm_error(LimitExceeded, "webm/time", "Timestamp overflows Int64", at))
  } else {
    Ok(a + b)
  }
}

///|
fn webm_i64_sub(a : Int64, b : Int64, at : Int) -> Result[Int64, DecodeError] {
  if b == WEBM_I64_MIN {
    Err(
      webm_error(LimitExceeded, "webm/time", "Timestamp underflows Int64", at),
    )
  } else {
    webm_i64_add(a, -b, at)
  }
}

///|
fn webm_scale_ticks(
  ticks : Int64,
  scale : Int64,
  at : Int,
) -> Result[Int64, DecodeError] {
  if scale <= 0L {
    return Err(
      webm_error(
        InvalidData,
        "webm/time",
        "TimestampScale must be positive",
        at,
      ),
    )
  }
  if ticks >= 0L {
    if ticks != 0L && ticks > WEBM_I64_MAX / scale {
      return Err(
        webm_error(LimitExceeded, "webm/time", "Timestamp overflows Int64", at),
      )
    }
    Ok(ticks * scale)
  } else {
    if ticks == WEBM_I64_MIN {
      if scale == 1L {
        return Ok(WEBM_I64_MIN)
      }
      return Err(
        webm_error(LimitExceeded, "webm/time", "Timestamp underflows Int64", at),
      )
    }
    let magnitude = -ticks
    if magnitude > WEBM_I64_MAX / scale {
      return Err(
        webm_error(LimitExceeded, "webm/time", "Timestamp underflows Int64", at),
      )
    }
    Ok(-(magnitude * scale))
  }
}

///|
fn webm_i64_mul_small(
  value : Int64,
  factor : Int,
  at : Int,
) -> Result[Int64, DecodeError] {
  if factor < 0 {
    return Err(webm_error(InvalidData, "webm/time", "Negative lace index", at))
  }
  let mut out = 0L
  for _ in 0..<factor {
    out = match webm_i64_add(out, value, at) {
      Ok(next) => next
      Err(error) => return Err(error)
    }
  }
  Ok(out)
}

///|
fn webm_unsigned_string_is(
  data : Array[Byte],
  start : Int,
  end : Int,
  expected : Array[Int],
) -> Bool {
  if end - start != expected.length() {
    return false
  }
  for i in 0..<expected.length() {
    if data[start + i].to_int() != expected[i] {
      return false
    }
  }
  true
}

///|
fn webm_is_av1_codec(data : Array[Byte], start : Int, end : Int) -> Bool {
  webm_unsigned_string_is(data, start, end, [86, 95, 65, 86, 49])
}

///|
fn webm_is_doctype(data : Array[Byte], start : Int, end : Int) -> Bool {
  webm_unsigned_string_is(data, start, end, [119, 101, 98, 109]) ||
  webm_unsigned_string_is(data, start, end, [
    109, 97, 116, 114, 111, 115, 107, 97,
  ])
}

///|
fn webm_element_children(
  data : Array[Byte],
  parent : WebmElement,
  out : Array[WebmElement],
  depth : Int,
) -> Result[Unit, DecodeError] {
  if depth > WEBM_MAX_NESTING {
    return Err(
      webm_error(
        LimitExceeded,
        "ebml",
        "EBML nesting exceeds the parser bound",
        parent.start,
      ),
    )
  }
  let mut at = parent.payload
  while at < parent.end {
    let child = match webm_read_element(data, at, parent.end) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if child.end <= at {
      return Err(
        webm_error(InvalidData, "ebml", "Element does not advance", at),
      )
    }
    if out.length() >= WEBM_MAX_ELEMENTS {
      return Err(
        webm_error(
          LimitExceeded,
          "ebml",
          "Element count exceeds parser bound",
          child.start,
        ),
      )
    }
    out.push(child)
    at = child.end
    if child.unknown {
      // Unknown-sized nested masters cannot be followed safely without their
      // schema level. The only unknown-sized elements accepted by this parser
      // are Segment and Cluster, handled by the enclosing walk.
      return Err(
        webm_error(
          Unsupported,
          "ebml",
          "Unknown-sized nested element",
          child.start,
        ),
      )
    }
  }
  if at != parent.end {
    Err(
      webm_error(
        TruncatedInput,
        "ebml",
        "Child walk stopped before parent end",
        at,
      ),
    )
  } else {
    Ok(())
  }
}

///|
fn webm_segment_child_id(id : Int64) -> Bool {
  id == 0x114D9B74 || // SeekHead
  id == WEBM_INFO ||
  id == WEBM_TRACKS ||
  id == 0x1C53BB6B || // Cues
  id == WEBM_CLUSTER ||
  id == 0x1043A770 || // Chapters
  id == 0x1941A469 || // Attachments
  id == 0x1254C367 || // Tags
  id == WEBM_VOID ||
  id == WEBM_CRC32
}

///|
fn webm_next_cluster(
  data : Array[Byte],
  start : Int,
  end : Int,
) -> Result[Int, DecodeError] {
  let mut at = start
  let mut scanned = 0
  while at < end {
    let candidate = match webm_read_element(data, at, end) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if candidate.id == WEBM_CLUSTER {
      return Ok(at)
    }
    if webm_segment_child_id(candidate.id) &&
      candidate.id != WEBM_VOID &&
      candidate.id != WEBM_CRC32 {
      return Ok(at)
    }
    if scanned >= WEBM_MAX_ELEMENTS {
      return Err(
        webm_error(
          LimitExceeded,
          "segment",
          "Unknown Cluster boundary scan exceeds parser bound",
          at,
        ),
      )
    }
    scanned += 1
    if candidate.unknown || candidate.end <= at {
      return Err(
        webm_error(
          Unsupported,
          "segment",
          "Cannot resolve unknown Cluster boundary",
          at,
        ),
      )
    }
    at = candidate.end
  }
  Ok(end)
}

///|
fn webm_segment_children(
  data : Array[Byte],
  segment : WebmElement,
) -> Result[Array[WebmElement], DecodeError] {
  let out : Array[WebmElement] = []
  let mut at = segment.payload
  while at < segment.end {
    let parsed = match webm_read_element(data, at, segment.end) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let child = if parsed.unknown {
      if parsed.id != WEBM_CLUSTER {
        return Err(
          webm_error(
            Unsupported,
            "segment",
            "Unknown-sized non-Cluster element",
            at,
          ),
        )
      }
      let end = match webm_next_cluster(data, parsed.payload, segment.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if end <= parsed.payload {
        return Err(
          webm_error(InvalidData, "segment", "Empty unknown-sized Cluster", at),
        )
      }
      { ..parsed, end, }
    } else {
      parsed
    }
    if child.end <= at {
      return Err(
        webm_error(InvalidData, "segment", "Segment child does not advance", at),
      )
    }
    if out.length() >= WEBM_MAX_ELEMENTS {
      return Err(
        webm_error(
          LimitExceeded,
          "segment",
          "Segment element count exceeds parser bound",
          child.start,
        ),
      )
    }
    out.push(child)
    at = child.end
  }
  if at != segment.end {
    return Err(
      webm_error(
        TruncatedInput,
        "segment",
        "Segment child walk stopped early",
        at,
      ),
    )
  }
  Ok(out)
}

///|
fn webm_parse_ebml_header(
  data : Array[Byte],
  ebml : WebmElement,
) -> Result[Unit, DecodeError] {
  if ebml.unknown {
    return Err(
      webm_error(
        InvalidData,
        "ebml",
        "EBML header cannot be unknown-sized",
        ebml.start,
      ),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, ebml, children, 1) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut doctype = false
  let mut ebml_version = false
  let mut ebml_read_version = false
  let mut max_id_length = false
  let mut max_size_length = false
  let mut doctype_version = false
  let mut doctype_read_version = false
  let mut doctype_version_value = 1L
  let mut doctype_read_version_value = 1L
  for child in children {
    if child.id == WEBM_EBML_VERSION {
      if ebml_version {
        return Err(
          webm_error(InvalidData, "ebml", "Duplicate EBMLVersion", child.start),
        )
      }
      ebml_version = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value != 1L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "Unsupported EBMLVersion",
            child.start,
          ),
        )
      }
    } else if child.id == WEBM_EBML_READ_VERSION {
      if ebml_read_version {
        return Err(
          webm_error(
            InvalidData,
            "ebml",
            "Duplicate EBMLReadVersion",
            child.start,
          ),
        )
      }
      ebml_read_version = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value != 1L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "Unsupported EBMLReadVersion",
            child.start,
          ),
        )
      }
    } else if child.id == WEBM_EBML_MAX_ID_LENGTH {
      if max_id_length {
        return Err(
          webm_error(
            InvalidData,
            "ebml",
            "Duplicate EBMLMaxIDLength",
            child.start,
          ),
        )
      }
      max_id_length = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value != 4L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "EBMLMaxIDLength must be four octets for WebM",
            child.start,
          ),
        )
      }
    } else if child.id == WEBM_EBML_MAX_SIZE_LENGTH {
      if max_size_length {
        return Err(
          webm_error(
            InvalidData,
            "ebml",
            "Duplicate EBMLMaxSizeLength",
            child.start,
          ),
        )
      }
      max_size_length = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value != 8L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "EBMLMaxSizeLength must be eight octets for WebM",
            child.start,
          ),
        )
      }
    } else if child.id == WEBM_DOCTYPE_VERSION {
      if doctype_version {
        return Err(
          webm_error(
            InvalidData,
            "ebml",
            "Duplicate DocTypeVersion",
            child.start,
          ),
        )
      }
      doctype_version = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value <= 0L || value > 4L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "Unsupported DocTypeVersion",
            child.start,
          ),
        )
      }
      doctype_version_value = value
    } else if child.id == WEBM_DOCTYPE_READ_VERSION {
      if doctype_read_version {
        return Err(
          webm_error(
            InvalidData,
            "ebml",
            "Duplicate DocTypeReadVersion",
            child.start,
          ),
        )
      }
      doctype_read_version = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value <= 0L || value > 4L {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "Unsupported DocTypeReadVersion",
            child.start,
          ),
        )
      }
      doctype_read_version_value = value
    } else if child.id == 0x4282L {
      if doctype || !webm_is_doctype(data, child.payload, child.end) {
        return Err(
          webm_error(
            Unsupported,
            "ebml",
            "Unsupported EBML DocType",
            child.start,
          ),
        )
      }
      doctype = true
    }
  }
  if !doctype {
    return Err(
      webm_error(InvalidData, "ebml", "EBML header misses DocType", ebml.start),
    )
  }
  if doctype_read_version_value > doctype_version_value {
    return Err(
      webm_error(
        Unsupported,
        "ebml",
        "DocTypeReadVersion exceeds DocTypeVersion",
        ebml.start,
      ),
    )
  }
  Ok(())
}

///|
fn webm_parse_info(
  data : Array[Byte],
  info : WebmElement,
) -> Result[Int64, DecodeError] {
  if info.unknown {
    return Err(
      webm_error(Unsupported, "info", "Unknown-sized Info element", info.start),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, info, children, 1) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut scale = WEBM_DEFAULT_TIMESTAMP_SCALE
  let mut seen = false
  for child in children {
    if child.id == WEBM_TIMECODE_SCALE {
      if seen {
        return Err(
          webm_error(
            InvalidData,
            "info",
            "Duplicate TimestampScale",
            child.start,
          ),
        )
      }
      seen = true
      scale = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if scale <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "info",
            "TimestampScale must be positive",
            child.start,
          ),
        )
      }
    }
  }
  Ok(scale)
}

///|
fn webm_parse_video(
  data : Array[Byte],
  video : WebmElement,
  width : Int,
  height : Int,
) -> Result[(Int, Int), DecodeError] {
  if video.unknown {
    return Err(
      webm_error(
        Unsupported,
        "track/video",
        "Unknown-sized Video element",
        video.start,
      ),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, video, children, 2) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut w = width
  let mut h = height
  for child in children {
    if child.id == WEBM_PIXEL_WIDTH {
      if w != 0 {
        return Err(
          webm_error(
            InvalidData,
            "track/video",
            "Duplicate PixelWidth",
            child.start,
          ),
        )
      }
      w = match webm_uint(data, child.payload, child.end) {
        Ok(value) => {
          if value > 2147483647L {
            return Err(
              webm_error(
                LimitExceeded,
                "track/video",
                "PixelWidth exceeds Int",
                child.start,
              ),
            )
          }
          value.to_int()
        }
        Err(error) => return Err(error)
      }
    } else if child.id == WEBM_PIXEL_HEIGHT {
      if h != 0 {
        return Err(
          webm_error(
            InvalidData,
            "track/video",
            "Duplicate PixelHeight",
            child.start,
          ),
        )
      }
      h = match webm_uint(data, child.payload, child.end) {
        Ok(value) => {
          if value > 2147483647L {
            return Err(
              webm_error(
                LimitExceeded,
                "track/video",
                "PixelHeight exceeds Int",
                child.start,
              ),
            )
          }
          value.to_int()
        }
        Err(error) => return Err(error)
      }
    }
  }
  Ok((w, h))
}

///|
fn webm_parse_track(
  data : Array[Byte],
  entry : WebmElement,
) -> Result[WebmTrack, DecodeError] {
  if entry.unknown {
    return Err(
      webm_error(Unsupported, "track", "Unknown-sized TrackEntry", entry.start),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, entry, children, 1) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut number = 0L
  let mut seen_number = false
  let mut track_type = 0
  let mut seen_track_type = false
  let mut codec_av1 = false
  let mut seen_codec = false
  let mut codec_private : Array[Byte]? = None
  let mut width = 0
  let mut height = 0
  let mut default_duration : Int64? = None
  let mut codec_delay : Int64? = None
  let mut flag_lacing = true
  let mut content_encoded = false
  let mut track_timestamp_scale_one = true
  let mut seen_flag_lacing = false
  let mut seen_content_encodings = false
  let mut seen_track_timestamp_scale = false
  let mut seen_video = false
  for child in children {
    if child.id == WEBM_TRACK_NUMBER {
      if seen_number {
        return Err(
          webm_error(InvalidData, "track", "Duplicate TrackNumber", child.start),
        )
      }
      seen_number = true
      number = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if number <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "TrackNumber must be positive",
            child.start,
          ),
        )
      }
    } else if child.id == WEBM_TRACK_TYPE {
      if seen_track_type {
        return Err(
          webm_error(InvalidData, "track", "Duplicate TrackType", child.start),
        )
      }
      seen_track_type = true
      track_type = match webm_uint(data, child.payload, child.end) {
        Ok(value) => {
          if value > 2147483647L {
            return Err(
              webm_error(
                LimitExceeded,
                "track",
                "TrackType exceeds Int",
                child.start,
              ),
            )
          }
          value.to_int()
        }
        Err(error) => return Err(error)
      }
    } else if child.id == WEBM_CODEC_ID {
      if seen_codec {
        return Err(
          webm_error(InvalidData, "track", "Duplicate CodecID", child.start),
        )
      }
      seen_codec = true
      codec_av1 = webm_is_av1_codec(data, child.payload, child.end)
    } else if child.id == WEBM_CODEC_PRIVATE {
      if codec_private is Some(_) {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "Duplicate CodecPrivate",
            child.start,
          ),
        )
      }
      codec_private = Some(webm_copy(data, child.payload, child.end))
    } else if child.id == WEBM_DEFAULT_DURATION {
      if default_duration is Some(_) {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "Duplicate DefaultDuration",
            child.start,
          ),
        )
      }
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "DefaultDuration must be positive",
            child.start,
          ),
        )
      }
      default_duration = Some(value)
    } else if child.id == WEBM_CODEC_DELAY {
      if codec_delay is Some(_) {
        return Err(
          webm_error(InvalidData, "track", "Duplicate CodecDelay", child.start),
        )
      }
      codec_delay = Some(
        match webm_uint(data, child.payload, child.end) {
          Ok(value) => value
          Err(error) => return Err(error)
        },
      )
    } else if child.id == WEBM_FLAG_LACING {
      if seen_flag_lacing {
        return Err(
          webm_error(InvalidData, "track", "Duplicate FlagLacing", child.start),
        )
      }
      seen_flag_lacing = true
      let value = match webm_uint(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if value > 1L {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "FlagLacing is not boolean",
            child.start,
          ),
        )
      }
      flag_lacing = value != 0L
    } else if child.id == WEBM_CONTENT_ENCODINGS {
      if seen_content_encodings {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "Duplicate ContentEncodings",
            child.start,
          ),
        )
      }
      seen_content_encodings = true
      content_encoded = true
    } else if child.id == WEBM_TRACK_TIMESTAMP_SCALE {
      if seen_track_timestamp_scale {
        return Err(
          webm_error(
            InvalidData,
            "track",
            "Duplicate TrackTimestampScale",
            child.start,
          ),
        )
      }
      seen_track_timestamp_scale = true
      // TrackTimestampScale is a floating point value. The common and exact
      // value is 1.0; other values need floating-point rounding semantics and
      // are rejected explicitly instead of being silently ignored.
      if child.end - child.payload == 8 &&
        data[child.payload].to_int() == 0x3F &&
        data[child.payload + 1].to_int() == 0xF0 &&
        data[child.payload + 2].to_int() == 0 &&
        data[child.payload + 3].to_int() == 0 &&
        data[child.payload + 4].to_int() == 0 &&
        data[child.payload + 5].to_int() == 0 &&
        data[child.payload + 6].to_int() == 0 &&
        data[child.payload + 7].to_int() == 0 {
        track_timestamp_scale_one = true
      } else if child.end - child.payload == 4 &&
        data[child.payload].to_int() == 0x3F &&
        data[child.payload + 1].to_int() == 0x80 &&
        data[child.payload + 2].to_int() == 0 &&
        data[child.payload + 3].to_int() == 0 {
        track_timestamp_scale_one = true
      } else {
        track_timestamp_scale_one = false
      }
    } else if child.id == WEBM_VIDEO {
      if seen_video {
        return Err(
          webm_error(InvalidData, "track", "Duplicate Video", child.start),
        )
      }
      seen_video = true
      let parsed = match webm_parse_video(data, child, width, height) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      width = parsed.0
      height = parsed.1
    }
  }
  if !seen_number || track_type == 0 || !seen_codec {
    return Err(
      webm_error(
        InvalidData,
        "track",
        "TrackEntry misses required fields",
        entry.start,
      ),
    )
  }
  Ok({
    number,
    track_type,
    codec_av1,
    codec_private,
    width,
    height,
    default_duration,
    codec_delay,
    flag_lacing,
    content_encoded,
    track_timestamp_scale_one,
  })
}

///|
fn webm_parse_tracks(
  data : Array[Byte],
  tracks_element : WebmElement,
) -> Result[Array[WebmTrack], DecodeError] {
  if tracks_element.unknown {
    return Err(
      webm_error(
        Unsupported,
        "tracks",
        "Unknown-sized Tracks element",
        tracks_element.start,
      ),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, tracks_element, children, 1) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let tracks : Array[WebmTrack] = []
  for child in children {
    if child.id != WEBM_TRACK_ENTRY {
      continue
    }
    let track = match webm_parse_track(data, child) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    for previous in tracks {
      if previous.number == track.number {
        return Err(
          webm_error(
            InvalidData,
            "tracks",
            "Duplicate TrackNumber",
            child.start,
          ),
        )
      }
    }
    if tracks.length() >= WEBM_MAX_TRACKS {
      return Err(
        webm_error(
          LimitExceeded,
          "tracks",
          "Track count exceeds parser bound",
          child.start,
        ),
      )
    }
    tracks.push(track)
  }
  if tracks.is_empty() {
    return Err(
      webm_error(
        InvalidData,
        "tracks",
        "Tracks element has no TrackEntry",
        tracks_element.start,
      ),
    )
  }
  Ok(tracks)
}

///|
fn webm_find_track(tracks : Array[WebmTrack], number : Int64) -> WebmTrack? {
  for track in tracks {
    if track.number == number {
      return Some(track)
    }
  }
  None
}

///|
fn webm_block_track(
  data : Array[Byte],
  start : Int,
  end : Int,
  tracks : Array[WebmTrack],
  block_group? : Bool = false,
) -> Result[WebmBlock, DecodeError] {
  if end - start < 4 {
    return Err(
      webm_error(TruncatedInput, "block", "Block header is incomplete", start),
    )
  }
  let track_vint = match webm_read_vint(data, start, end) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if track_vint.unknown || track_vint.value <= 0 {
    return Err(
      webm_error(InvalidData, "block", "Invalid Block track number", start),
    )
  }
  let track = track_vint.value
  let time_at = start + track_vint.width
  if time_at + 3 > end {
    return Err(
      webm_error(
        TruncatedInput,
        "block",
        "Block timecode is incomplete",
        time_at,
      ),
    )
  }
  let time_u = data[time_at].to_int() * 256 + data[time_at + 1].to_int()
  let timecode = if time_u >= 32768 {
    (time_u - 65536).to_int64()
  } else {
    time_u.to_int64()
  }
  let flags = data[time_at + 2].to_int()
  if (flags & 0x70) != 0 || (block_group && (flags & 0x80) != 0) {
    return Err(
      webm_error(
        InvalidData,
        "block",
        "Reserved Block flags are set",
        time_at + 2,
      ),
    )
  }
  let track_info = match webm_find_track(tracks, track) {
    Some(value) => value
    None =>
      return Err(
        webm_error(
          InvalidData,
          "block",
          "Block references an unknown track",
          start,
        ),
      )
  }
  let lace_mode = (flags >> 1) & 3
  if lace_mode != 0 && !track_info.flag_lacing {
    return Err(
      webm_error(
        InvalidData,
        "block",
        "Lacing is disabled for this track",
        time_at + 2,
      ),
    )
  }
  let payload = time_at + 3
  let frames : Array[WebmFrameSpan] = []
  if lace_mode == 0 {
    if payload >= end {
      return Err(webm_error(InvalidData, "block", "Empty Block frame", payload))
    }
    frames.push({ start: payload, end, })
  } else {
    if payload >= end {
      return Err(
        webm_error(
          TruncatedInput,
          "block",
          "Missing lacing frame count",
          payload,
        ),
      )
    }
    let count = data[payload].to_int() + 1
    if count < 2 {
      return Err(
        webm_error(
          InvalidData,
          "block",
          "Lacing must contain at least two frames",
          payload,
        ),
      )
    }
    let mut at = payload + 1
    let sizes : Array[Int] = []
    if lace_mode == 1 {
      // Xiph lacing stores the first count-1 sizes as 255-terminated sums.
      for _ in 0..<(count - 1) {
        let mut size = 0
        let mut terminated = false
        while at < end {
          let byte = data[at].to_int()
          at += 1
          if size > 0x7FFFFFFF - byte {
            return Err(
              webm_error(
                LimitExceeded,
                "block/lacing",
                "Xiph frame size overflows Int",
                at - 1,
              ),
            )
          }
          size += byte
          if byte != 255 {
            terminated = true
            break
          }
        }
        if !terminated || size <= 0 {
          return Err(
            webm_error(
              TruncatedInput,
              "block/lacing",
              "Truncated Xiph frame size",
              at,
            ),
          )
        }
        sizes.push(size)
      }
    } else if lace_mode == 2 {
      let remaining = end - at
      if remaining <= 0 || remaining % count != 0 {
        return Err(
          webm_error(
            InvalidData,
            "block/lacing",
            "Fixed lacing payload is not divisible",
            at,
          ),
        )
      }
      let size = remaining / count
      if size <= 0 {
        return Err(
          webm_error(
            InvalidData,
            "block/lacing",
            "Fixed lacing contains empty frame",
            at,
          ),
        )
      }
      for _ in 0..<(count - 1) {
        sizes.push(size)
      }
    } else {
      let first_size = match webm_read_vint(data, at, end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if first_size.unknown || first_size.value <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "block/lacing",
            "Invalid EBML first lace size",
            at,
          ),
        )
      }
      if first_size.value > (end - at - first_size.width).to_int64() {
        return Err(
          webm_error(
            TruncatedInput,
            "block/lacing",
            "EBML first lace exceeds Block",
            at,
          ),
        )
      }
      sizes.push(first_size.value.to_int())
      at += first_size.width
      let mut previous = first_size.value
      for _ in 0..<(count - 2) {
        let encoded = match webm_read_vint(data, at, end) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if encoded.unknown {
          return Err(
            webm_error(
              InvalidData,
              "block/lacing",
              "Unknown EBML lace size",
              at,
            ),
          )
        }
        let bits = 7 * encoded.width - 1
        let mut power = 1L
        for _ in 0..<bits {
          power *= 2L
        }
        let bias = power - 1L
        let delta = encoded.value - bias
        let next = match webm_i64_add(previous, delta, at) {
          Ok(value) => value
          Err(error) => return Err(error)
        }
        if next <= 0L || next > (end - at).to_int64() {
          return Err(
            webm_error(
              InvalidData,
              "block/lacing",
              "EBML lace size is invalid",
              at,
            ),
          )
        }
        sizes.push(next.to_int())
        previous = next
        at += encoded.width
      }
    }
    let mut used = 0
    for size in sizes {
      if size <= 0 || size > end - at - used {
        return Err(
          webm_error(
            TruncatedInput,
            "block/lacing",
            "Laced frame exceeds Block",
            at,
          ),
        )
      }
      frames.push({ start: at + used, end: at + used + size, })
      used += size
    }
    let last = end - at - used
    if last <= 0 {
      return Err(
        webm_error(
          InvalidData,
          "block/lacing",
          "Laced final frame is empty",
          at + used,
        ),
      )
    }
    frames.push({ start: at + used, end, })
  }
  Ok({ timecode, frames, keyframe: !block_group && (flags & 0x80) != 0, })
}

///|
fn webm_block_track_number(
  data : Array[Byte],
  start : Int,
  end : Int,
) -> Result[Int64, DecodeError] {
  let track_vint = match webm_read_vint(data, start, end) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if track_vint.unknown || track_vint.value <= 0L {
    return Err(
      webm_error(InvalidData, "block", "Invalid Block track number", start),
    )
  }
  Ok(track_vint.value)
}

///|
fn webm_cluster_packets(
  data : Array[Byte],
  cluster : WebmElement,
  tracks : Array[WebmTrack],
  selected : WebmTrack,
  max_frames : Int,
  out : Array[WebmRawPacket],
) -> Result[Unit, DecodeError] {
  if cluster.unknown {
    // segment_children assigned the effective end for unknown Clusters.
    return Err(
      webm_error(
        InvalidData,
        "cluster",
        "Cluster boundary was not resolved",
        cluster.start,
      ),
    )
  }
  let children : Array[WebmElement] = []
  match webm_element_children(data, cluster, children, 2) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut timestamp : Int64? = None
  let pending : Array[(WebmBlock, Int64?, Bool, Bool)] = []
  let mut pending_selected_frames = 0
  for child in children {
    if child.id == WEBM_CLUSTER_TIMESTAMP {
      if timestamp is Some(_) {
        return Err(
          webm_error(
            InvalidData,
            "cluster",
            "Duplicate Cluster Timestamp",
            child.start,
          ),
        )
      }
      timestamp = Some(
        match webm_uint(data, child.payload, child.end) {
          Ok(value) => value
          Err(error) => return Err(error)
        },
      )
    } else if child.id == WEBM_SIMPLE_BLOCK {
      let block_track = match
        webm_block_track_number(data, child.payload, child.end) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if webm_find_track(tracks, block_track) is None {
        return Err(
          webm_error(
            InvalidData,
            "block",
            "Block references an unknown track",
            child.start,
          ),
        )
      }
      if block_track != selected.number {
        continue
      }
      let block = match
        webm_block_track(data, child.payload, child.end, tracks) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      let remaining = max_frames - out.length() - pending_selected_frames
      if block.frames.length() > remaining {
        return Err(
          webm_error(
            LimitExceeded,
            "webm",
            "Packet count exceeds max_frames",
            child.start,
          ),
        )
      }
      pending_selected_frames += block.frames.length()
      pending.push((block, None, false, false))
    } else if child.id == WEBM_BLOCK_GROUP {
      if child.unknown {
        return Err(
          webm_error(
            Unsupported,
            "cluster/blockgroup",
            "Unknown-sized BlockGroup",
            child.start,
          ),
        )
      }
      let group_children : Array[WebmElement] = []
      match webm_element_children(data, child, group_children, 3) {
        Err(error) => return Err(error)
        Ok(_) => ()
      }
      let mut block : WebmBlock? = None
      let mut saw_block = false
      let mut duration : Int64? = None
      let mut reference = false
      let mut reference_zero = false
      let mut unsupported_extra = false
      for item in group_children {
        if item.id == WEBM_BLOCK {
          if saw_block {
            return Err(
              webm_error(
                InvalidData,
                "cluster/blockgroup",
                "Duplicate Block",
                item.start,
              ),
            )
          }
          saw_block = true
          let block_track = match
            webm_block_track_number(data, item.payload, item.end) {
            Ok(value) => value
            Err(error) => return Err(error)
          }
          if webm_find_track(tracks, block_track) is None {
            return Err(
              webm_error(
                InvalidData,
                "block",
                "Block references an unknown track",
                item.start,
              ),
            )
          }
          if block_track == selected.number {
            block = Some(
              match
                webm_block_track(
                  data,
                  item.payload,
                  item.end,
                  tracks,
                  block_group=true,
                ) {
                Ok(value) => value
                Err(error) => return Err(error)
              },
            )
          }
        } else if item.id == WEBM_BLOCK_DURATION {
          if duration is Some(_) {
            return Err(
              webm_error(
                InvalidData,
                "cluster/blockgroup",
                "Duplicate BlockDuration",
                item.start,
              ),
            )
          }
          duration = Some(
            match webm_uint(data, item.payload, item.end) {
              Ok(value) => value
              Err(error) => return Err(error)
            },
          )
        } else if item.id == WEBM_REFERENCE_BLOCK {
          if item.end <= item.payload || item.end - item.payload > 8 {
            return Err(
              webm_error(
                InvalidData,
                "cluster/blockgroup",
                "Invalid ReferenceBlock integer",
                item.start,
              ),
            )
          }
          let mut zero = true
          for position in item.payload..<item.end {
            if data[position].to_int() != 0 {
              zero = false
            }
          }
          if reference_zero || (zero && reference) {
            return Err(
              webm_error(
                InvalidData,
                "cluster/blockgroup",
                "ReferenceBlock zero must be the only reference",
                item.start,
              ),
            )
          }
          if zero {
            reference_zero = true
          }
          reference = true
        } else if item.id == WEBM_CODEC_STATE ||
          item.id == WEBM_DISCARD_PADDING ||
          item.id == WEBM_BLOCK_ADDITIONS {
          unsupported_extra = true
        }
      }
      if !saw_block {
        return Err(
          webm_error(
            InvalidData,
            "cluster/blockgroup",
            "BlockGroup has no Block",
            child.start,
          ),
        )
      }
      let value = match block {
        Some(value) => value
        None => continue
      }
      if unsupported_extra {
        return Err(
          webm_error(
            Unsupported,
            "cluster/blockgroup",
            "Unsupported BlockGroup payload",
            child.start,
          ),
        )
      }
      let remaining = max_frames - out.length() - pending_selected_frames
      if value.frames.length() > remaining {
        return Err(
          webm_error(
            LimitExceeded,
            "webm",
            "Packet count exceeds max_frames",
            child.start,
          ),
        )
      }
      pending_selected_frames += value.frames.length()
      pending.push((value, duration, reference, true))
    }
  }
  let cluster_time = match timestamp {
    Some(value) => value
    None =>
      return Err(
        webm_error(
          InvalidData,
          "cluster",
          "Cluster has no Timestamp",
          cluster.start,
        ),
      )
  }
  for item in pending {
    let (block, duration, reference, is_block_group) = item
    let base_ticks = match
      webm_i64_add(cluster_time, block.timecode, block.frames[0].start) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let frame_count = block.frames.length()
    for i in 0..<frame_count {
      let frame = block.frames[i]
      if out.length() >= max_frames {
        return Err(
          webm_error(
            LimitExceeded,
            "webm",
            "Packet count exceeds max_frames",
            frame.start,
          ),
        )
      }
      out.push({
        frame,
        track_ticks: base_ticks,
        duration_ticks: duration,
        laced_index: i,
        laced_count: frame_count,
        keyframe: if reference {
          false
        } else if is_block_group {
          true
        } else {
          block.keyframe
        },
        reference,
      })
    }
  }
  Ok(())
}

///|
fn webm_laced_timing(
  ticks : Int64?,
  default_duration : Int64?,
  scale : Int64,
  count : Int,
  index : Int,
  at : Int,
) -> Result[(Int64?, Int64?), DecodeError] {
  if index < 0 || index >= count || count <= 0 {
    return Err(
      webm_error(InvalidData, "webm/time", "Invalid lace timing index", at),
    )
  }
  if count == 1 {
    let duration = match ticks {
      Some(value) => {
        if value <= 0L {
          return Err(
            webm_error(
              InvalidData,
              "webm/time",
              "BlockDuration must be positive",
              at,
            ),
          )
        }
        Some(
          match webm_scale_ticks(value, scale, at) {
            Ok(result) => result
            Err(error) => return Err(error)
          },
        )
      }
      None => default_duration
    }
    return Ok((duration, Some(0L)))
  }
  let total = match ticks {
    Some(value) => {
      if value <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "webm/time",
            "BlockDuration must be positive",
            at,
          ),
        )
      }
      Some(
        match webm_scale_ticks(value, scale, at) {
          Ok(result) => result
          Err(error) => return Err(error)
        },
      )
    }
    None => None
  }
  match (total, default_duration) {
    (None, None) =>
      if index == 0 {
        Ok((None, Some(0L)))
      } else {
        Ok((None, None))
      }
    (None, Some(default)) => {
      let offset = match webm_i64_mul_small(default, index, at) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      Ok((Some(default), Some(offset)))
    }
    (Some(total), None) => {
      let base = total / count.to_int64()
      let remainder = total % count.to_int64()
      if base <= 0L {
        return Err(
          webm_error(
            InvalidData,
            "webm/time",
            "BlockDuration is shorter than its lace",
            at,
          ),
        )
      }
      let offset = match webm_i64_mul_small(base, index, at) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      let duration = if index == count - 1 { base + remainder } else { base }
      Ok((Some(duration), Some(offset)))
    }
    (Some(total), Some(default)) => {
      let preceding = match webm_i64_mul_small(default, count - 1, at) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      if total <= preceding {
        return Err(
          webm_error(
            InvalidData,
            "webm/time",
            "BlockDuration contradicts DefaultDuration",
            at,
          ),
        )
      }
      let offset = match webm_i64_mul_small(default, index, at) {
        Ok(result) => result
        Err(error) => return Err(error)
      }
      let duration = if index == count - 1 {
        total - preceding
      } else {
        default
      }
      Ok((Some(duration), Some(offset)))
    }
  }
}

///|
/// Parse a WebM/Matroska file carrying a V_AV1 video track.
///
/// `track_id` selects Matroska TrackNumber (not TrackUID). If omitted, the
/// first AV1 video TrackEntry is selected. All returned packet buffers and the
/// AV1 initialization OBUs own their bytes independently of `data`.
pub fn av1_demux_webm(
  data : Array[Byte],
  track_id? : Int64? = None,
  limits? : DecodeLimits = DecodeLimits::default(),
) -> Result[Av1DemuxedTrack, DecodeError] {
  match av1_demux_validate_input(data, limits) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  if data.is_empty() {
    return Err(
      decode_error(
        TruncatedInput,
        "webm",
        "Empty WebM/Matroska input",
        offset=Some(0),
      ),
    )
  }
  let ebml = match webm_read_element(data, 0, data.length()) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  if ebml.id != WEBM_EBML {
    return Err(
      webm_error(
        InvalidData,
        "webm",
        "Input does not start with EBML",
        ebml.start,
      ),
    )
  }
  match webm_parse_ebml_header(data, ebml) {
    Err(error) => return Err(error)
    Ok(_) => ()
  }
  let mut root_at = ebml.end
  let mut segment : WebmElement? = None
  while root_at < data.length() {
    let element = match webm_read_element(data, root_at, data.length()) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    if element.id == WEBM_SEGMENT {
      if segment is Some(_) {
        return Err(
          webm_error(
            InvalidData,
            "webm",
            "Duplicate Segment element",
            element.start,
          ),
        )
      }
      segment = Some(element)
      break
    } else if element.id == WEBM_VOID || element.id == WEBM_CRC32 {
      if element.unknown {
        return Err(
          webm_error(
            Unsupported,
            "webm",
            "Unknown-sized root Void/CRC",
            element.start,
          ),
        )
      }
      root_at = element.end
    } else {
      return Err(
        webm_error(
          InvalidData,
          "webm",
          "Missing Segment element",
          element.start,
        ),
      )
    }
  }
  let segment = match segment {
    Some(value) => value
    None =>
      return Err(
        webm_error(TruncatedInput, "webm", "Missing Segment element", root_at),
      )
  }
  if !segment.unknown {
    let mut trailing_at = segment.end
    while trailing_at < data.length() {
      let trailing = match webm_read_element(data, trailing_at, data.length()) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
      if trailing.id == WEBM_SEGMENT {
        return Err(
          webm_error(
            Unsupported,
            "webm",
            "Multiple Segment elements are unsupported",
            trailing.start,
          ),
        )
      }
      if trailing.id != WEBM_VOID && trailing.id != WEBM_CRC32 {
        return Err(
          webm_error(
            InvalidData,
            "webm",
            "Unexpected non-global data after Segment",
            trailing.start,
          ),
        )
      }
      if trailing.unknown || trailing.end <= trailing_at {
        return Err(
          webm_error(
            Unsupported,
            "webm",
            "Unknown-sized root Void/CRC",
            trailing.start,
          ),
        )
      }
      trailing_at = trailing.end
    }
  }
  let segment_end = if segment.unknown { data.length() } else { segment.end }
  let segment = { ..segment, end: segment_end, }
  let children = match webm_segment_children(data, segment) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let mut timestamp_scale = WEBM_DEFAULT_TIMESTAMP_SCALE
  let mut tracks : Array[WebmTrack] = []
  let clusters : Array[WebmElement] = []
  let mut saw_info = false
  let mut saw_tracks = false
  for child in children {
    if child.id == WEBM_INFO {
      if saw_info {
        return Err(
          webm_error(
            InvalidData,
            "segment",
            "Duplicate Info element",
            child.start,
          ),
        )
      }
      saw_info = true
      timestamp_scale = match webm_parse_info(data, child) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    } else if child.id == WEBM_TRACKS {
      if saw_tracks {
        return Err(
          webm_error(
            InvalidData,
            "segment",
            "Duplicate Tracks element",
            child.start,
          ),
        )
      }
      saw_tracks = true
      tracks = match webm_parse_tracks(data, child) {
        Ok(value) => value
        Err(error) => return Err(error)
      }
    } else if child.id == WEBM_CLUSTER {
      clusters.push(child)
    }
  }
  if !saw_info || !saw_tracks {
    return Err(
      webm_error(
        InvalidData,
        "segment",
        "Segment lacks Info or Tracks",
        segment.start,
      ),
    )
  }
  let selected = match track_id {
    Some(requested) =>
      match webm_find_track(tracks, requested) {
        Some(value) => value
        None =>
          return Err(
            webm_error(
              InvalidData,
              "tracks",
              "Requested TrackNumber was not found",
              segment.start,
            ),
          )
      }
    None => {
      let mut found : WebmTrack? = None
      for track in tracks {
        if track.track_type == 1 && track.codec_av1 {
          found = Some(track)
          break
        }
      }
      match found {
        Some(value) => value
        None =>
          return Err(
            webm_error(
              Unsupported,
              "tracks",
              "No AV1 video TrackEntry",
              segment.start,
            ),
          )
      }
    }
  }
  if selected.track_type != 1 || !selected.codec_av1 {
    return Err(
      webm_error(
        Unsupported,
        "tracks",
        "Selected track is not V_AV1 video",
        segment.start,
      ),
    )
  }
  if selected.content_encoded {
    return Err(
      webm_error(
        Unsupported,
        "tracks",
        "Compressed or encrypted TrackEntry is unsupported",
        segment.start,
      ),
    )
  }
  if !selected.track_timestamp_scale_one {
    return Err(
      webm_error(
        Unsupported,
        "tracks",
        "Non-unit TrackTimestampScale is unsupported",
        segment.start,
      ),
    )
  }
  if selected.width <= 0 || selected.height <= 0 {
    return Err(
      webm_error(
        InvalidData,
        "tracks/video",
        "V_AV1 track has no PixelWidth/PixelHeight",
        segment.start,
      ),
    )
  }
  if selected.width > limits.max_frame_pixels / selected.height {
    return Err(
      webm_error(
        LimitExceeded,
        "tracks/video",
        "Track dimensions exceed max_frame_pixels",
        segment.start,
      ),
    )
  }
  let codec_private = match selected.codec_private {
    Some(value) => value
    None =>
      return Err(
        webm_error(
          InvalidData,
          "tracks",
          "V_AV1 track has no CodecPrivate",
          segment.start,
        ),
      )
  }
  let codec_initialization = match av1_demux_av1c(codec_private) {
    Ok(value) => value
    Err(error) => return Err(error)
  }
  let sequence = match av1_sequence_info(codec_initialization) {
    Some(value) => value
    None =>
      return Err(
        webm_error(
          InvalidData,
          "tracks/video",
          "CodecPrivate has no usable sequence header",
          segment.start,
        ),
      )
  }
  if selected.width != sequence.width || selected.height != sequence.height {
    return Err(
      webm_error(
        InvalidData,
        "tracks/video",
        "Pixel dimensions do not match AV1 sequence maxima",
        segment.start,
      ),
    )
  }
  let raw : Array[WebmRawPacket] = []
  for cluster in clusters {
    // Unknown-sized Clusters are assigned an effective end by the enclosing
    // Segment walk, therefore treat them as finite for child parsing.
    let finite_cluster = { ..cluster, unknown: false, }
    match
      webm_cluster_packets(
        data,
        finite_cluster,
        tracks,
        selected,
        limits.max_frames,
        raw,
      ) {
      Err(error) => return Err(error)
      Ok(_) => ()
    }
    if raw.length() > limits.max_frames {
      return Err(
        webm_error(
          LimitExceeded,
          "webm",
          "Packet count exceeds max_frames",
          cluster.start,
        ),
      )
    }
  }
  let packets : Array[Av1Packet] = []
  for item in raw {
    let timing = match
      webm_laced_timing(
        item.duration_ticks,
        selected.default_duration,
        timestamp_scale,
        item.laced_count,
        item.laced_index,
        item.frame.start,
      ) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let duration = timing.0
    let timestamp_base = match
      webm_scale_ticks(item.track_ticks, timestamp_scale, item.frame.start) {
      Ok(value) => value
      Err(error) => return Err(error)
    }
    let timestamp_unshifted : Int64? = match timing.1 {
      Some(offset) =>
        Some(
          match webm_i64_add(timestamp_base, offset, item.frame.start) {
            Ok(result) => result
            Err(error) => return Err(error)
          },
        )
      None => None
    }
    // CodecDelay shifts the timestamp used for presentation in Matroska. It
    // is not a decode timestamp, so DTS remains unknown unless a future
    // container extension supplies an explicit decode-order field.
    let timestamp = match timestamp_unshifted {
      Some(value) =>
        match selected.codec_delay {
          Some(delay) =>
            Some(
              match webm_i64_sub(value, delay, item.frame.start) {
                Ok(result) => result
                Err(error) => return Err(error)
              },
            )
          None => Some(value)
        }
      None => None
    }
    packets.push({
      data: webm_copy(data, item.frame.start, item.frame.end),
      presentation_timestamp: timestamp,
      decode_timestamp: None,
      duration,
      sync_sample: Some(item.keyframe && !item.reference),
    })
  }
  Ok({
    format: WebM,
    track_id: selected.number,
    width: selected.width,
    height: selected.height,
    timescale: WEBM_NANOS,
    movie_timescale: None,
    edits: [],
    codec_initialization,
    packets,
  })
}
