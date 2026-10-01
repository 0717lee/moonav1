///|
/// File-backed long-container verification. Host adapters only read bytes;
/// demuxing, packet checks and all AV1 decoding run in MoonBit.
struct ExpectedPacket {
  flags : Int
  pts : Int64
  dts : Int64
  duration : Int64
  size : Int
  crc : UInt
}

///|
struct ExpectedContainer {
  schema_version : Int
  format : @moonav1.Av1ContainerFormat
  width : Int
  height : Int
  declared_width : Int
  declared_height : Int
  depth : Int
  sampling_x : Bool
  sampling_y : Bool
  full_range : Bool
  color_primaries : Int
  transfer_characteristics : Int
  matrix_coefficients : Int
  timescale : Int64
  packet_count : Int
  frame_count : Int
  frame_bytes : Int
  max_total_pixels : Int
  packets : Array[ExpectedPacket]
  native_frame_index_for_packet : Array[Int]
  frame_crc32 : Array[UInt]
  chunk_sizes : Array[Int]
}

///|
struct StreamRun {
  frames : Int
  samples : Int64
  peak_pending : Int
  pre_eof : Bool
  terminal : @moonav1.Av1ContainerStreamStatus
}

///|
fn require(value : Bool, message : String) -> Unit {
  if !value {
    println("FAIL " + message)
    abort(message)
  }
}

///|
fn read_byte(kind : Int) -> Int {
  let value = io_read(kind)
  if value < 0 {
    require(false, "Unexpected EOF or file error on input \{kind}")
  }
  value
}

///|
fn read_u32(kind : Int) -> UInt {
  let mut value = 0U
  for i in 0..<4 {
    value = value | (read_byte(kind).reinterpret_as_uint() << (8 * i))
  }
  value
}

///|
fn read_i64(kind : Int) -> Int64 {
  let mut value = 0L
  for i in 0..<8 {
    value = value | (read_byte(kind).to_int64() << (8 * i))
  }
  value
}

///|
fn read_i32(kind : Int) -> Int {
  read_u32(kind).reinterpret_as_int()
}

///|
fn packet_crc32(data : Array[Byte]) -> UInt {
  let mut crc = 0xFFFFFFFFU
  for byte in data {
    crc = crc ^ byte.to_uint()
    for _ in 0..<8 {
      if (crc & 1U) != 0U {
        crc = (crc >> 1) ^ 0xEDB88320U
      } else {
        crc = crc >> 1
      }
    }
  }
  crc ^ 0xFFFFFFFFU
}

///|
fn format_from_code(code : Int) -> @moonav1.Av1ContainerFormat {
  match code {
    0 => @moonav1.Ivf
    1 => @moonav1.Mp4
    2 => @moonav1.WebM
    _ => {
      require(false, "Unknown container format code")
      @moonav1.Ivf
    }
  }
}

///|
fn read_expectation() -> ExpectedContainer {
  require(io_open(2) == 2, "Cannot open expectation manifest")
  require(read_byte(2) == b'L'.to_int(), "Expectation magic mismatch")
  require(read_byte(2) == b'C'.to_int(), "Expectation magic mismatch")
  require(read_byte(2) == b'E'.to_int(), "Expectation magic mismatch")
  let version = read_byte(2)
  let expected = if version == b'1'.to_int() {
    let format = format_from_code(read_u32(2).reinterpret_as_int())
    let width = read_u32(2).reinterpret_as_int()
    let height = read_u32(2).reinterpret_as_int()
    let depth = read_u32(2).reinterpret_as_int()
    let timescale = read_i64(2)
    let packet_count = read_u32(2).reinterpret_as_int()
    let frame_count = read_u32(2).reinterpret_as_int()
    let frame_bytes = read_u32(2).reinterpret_as_int()
    let packets = read_packets(2, packet_count)
    let chunk_sizes = read_chunks(2)
    {
      schema_version: 1,
      format,
      width,
      height,
      declared_width: width,
      declared_height: height,
      depth,
      sampling_x: true,
      sampling_y: true,
      full_range: false,
      color_primaries: 1,
      transfer_characteristics: 1,
      matrix_coefficients: 1,
      timescale,
      packet_count,
      frame_count,
      frame_bytes,
      max_total_pixels: 128 * 1024 * 1024,
      packets,
      native_frame_index_for_packet: Array::makei(packet_count, i => i),
      frame_crc32: [],
      chunk_sizes,
    }
  } else {
    require(version == b'2'.to_int(), "Expectation magic mismatch")
    let format = format_from_code(read_u32(2).reinterpret_as_int())
    let width = read_u32(2).reinterpret_as_int()
    let height = read_u32(2).reinterpret_as_int()
    let declared_width = read_u32(2).reinterpret_as_int()
    let declared_height = read_u32(2).reinterpret_as_int()
    let depth = read_u32(2).reinterpret_as_int()
    let sampling = read_u32(2).reinterpret_as_int()
    require(
      sampling == 1 || sampling == 2,
      "Unsupported native reference sampling",
    )
    let full_range = read_u32(2).reinterpret_as_int() != 0
    let color_primaries = read_u32(2).reinterpret_as_int()
    let transfer_characteristics = read_u32(2).reinterpret_as_int()
    let matrix_coefficients = read_u32(2).reinterpret_as_int()
    let packet_count = read_u32(2).reinterpret_as_int()
    let frame_count = read_u32(2).reinterpret_as_int()
    let frame_bytes = read_u32(2).reinterpret_as_int()
    let max_total_pixels = read_u32(2).reinterpret_as_int()
    let timescale = read_i64(2)
    let mapping_count = read_u32(2).reinterpret_as_int()
    require(
      mapping_count == packet_count,
      "Packet/native mapping count differs",
    )
    let mapping = Array::makei(mapping_count, _ => read_i32(2))
    let frame_crc32 = Array::makei(frame_count, _ => read_u32(2))
    let packets = read_packets(2, packet_count)
    let chunk_sizes = read_chunks(2)
    {
      schema_version: 2,
      format,
      width,
      height,
      declared_width,
      declared_height,
      depth,
      sampling_x: sampling == 1,
      sampling_y: sampling == 1,
      full_range,
      color_primaries,
      transfer_characteristics,
      matrix_coefficients,
      timescale,
      packet_count,
      frame_count,
      frame_bytes,
      max_total_pixels,
      packets,
      native_frame_index_for_packet: mapping,
      frame_crc32,
      chunk_sizes,
    }
  }
  require(io_read(2) == -1, "Unexpected bytes after expectation manifest")
  io_close(2)
  expected
}

///|
fn read_packets(kind : Int, packet_count : Int) -> Array[ExpectedPacket] {
  let packets : Array[ExpectedPacket] = []
  for _ in 0..<packet_count {
    let flags = read_byte(kind)
    let pts = read_i64(kind)
    let dts = read_i64(kind)
    let duration = read_i64(kind)
    let size = read_u32(kind).reinterpret_as_int()
    let crc = read_u32(kind)
    packets.push({ flags, pts, dts, duration, size, crc, })
  }
  packets
}

///|
fn read_chunks(kind : Int) -> Array[Int] {
  let chunk_count = read_u32(kind).reinterpret_as_int()
  require(chunk_count > 0, "Empty chunk sequence")
  Array::makei(chunk_count, _ => read_u32(kind).reinterpret_as_int())
}

///|
fn read_all_input(kind? : Int = 0) -> Array[Byte] {
  require(io_open(kind) == kind, "Cannot open container input")
  let data : Array[Byte] = []
  while true {
    let value = io_read(kind)
    if value == -1 {
      break
    }
    require(value >= 0, "Container input read failed")
    data.push(value.to_byte())
  }
  io_close(kind)
  data
}

///|
fn assert_optional(
  actual : Int64?,
  expected : Int64,
  flags : Int,
  bit : Int,
  label : String,
) -> Unit {
  if (flags & bit) != 0 {
    require(actual == Some(expected), label + " differs")
  } else {
    require(actual is None, label + " unexpectedly present")
  }
}

///|
fn assert_sync(actual : Bool?, expected : ExpectedPacket) -> Unit {
  if (expected.flags & 8) != 0 {
    let value = (expected.flags & 16) != 0
    require(actual == Some(value), "sync marker differs")
  } else {
    require(actual is None, "sync marker unexpectedly present")
  }
}

///|
fn verify_packet(
  packet : @moonav1.Av1Packet,
  expected : ExpectedPacket,
) -> Unit {
  assert_optional(
    packet.presentation_timestamp,
    expected.pts,
    expected.flags,
    1,
    "PTS",
  )
  assert_optional(
    packet.decode_timestamp,
    expected.dts,
    expected.flags,
    2,
    "DTS",
  )
  assert_optional(
    packet.duration,
    expected.duration,
    expected.flags,
    4,
    "duration",
  )
  assert_sync(packet.sync_sample, expected)
  require(packet.data.length() == expected.size, "Packet size differs")
  require(packet_crc32(packet.data) == expected.crc, "Packet data CRC differs")
}

///|
fn verify_track(
  format : @moonav1.Av1ContainerFormat,
  width : Int,
  height : Int,
  timescale : Int64,
  packets : Int,
  expected : ExpectedContainer,
) -> Unit {
  require(format == expected.format, "Container format differs")
  require(
    width == expected.declared_width && height == expected.declared_height,
    "Track geometry differs",
  )
  require(timescale == expected.timescale, "Track timescale differs")
  require(packets == expected.packet_count, "Packet count differs")
}

///|
fn verify_native_frame(
  frame : @moonav1.Av1NativeFrame,
  index : Int,
  expected : ExpectedContainer,
) -> Int64 {
  require(
    frame.width == expected.width && frame.height == expected.height,
    "Frame geometry differs",
  )
  require(frame.bit_depth == expected.depth, "Frame bit depth differs")
  require(
    frame.planes.length() == 3,
    "Container fixture must be three-plane YUV",
  )
  require(
    frame.subsampling_x == expected.sampling_x &&
    frame.subsampling_y == expected.sampling_y,
    "Native sampling differs",
  )
  require(frame.full_range == expected.full_range, "Frame range differs")
  require(
    frame.color_primaries == expected.color_primaries &&
    frame.transfer_characteristics == expected.transfer_characteristics &&
    frame.matrix_coefficients == expected.matrix_coefficients,
    "Frame color metadata differs",
  )
  let reference = read_reference_frame(expected, index)
  let mut at = 0
  let mut count : Int64 = 0L
  for p in 0..<frame.planes.length() {
    let plane = frame.planes[p]
    let dx = if p == 0 || !expected.sampling_x { 1 } else { 2 }
    let dy = if p == 0 || !expected.sampling_y { 1 } else { 2 }
    let width = (frame.width + dx - 1) / dx
    let height = (frame.height + dy - 1) / dy
    require(
      plane.width == width && plane.height == height,
      "Plane extent differs",
    )
    require(plane.data.length() == width * height, "Plane sample count differs")
    for sample in plane.data {
      let expected_sample = if expected.depth <= 8 {
        require(at < reference.length(), "Native reference frame is truncated")
        let value = reference[at].to_int()
        at += 1
        value
      } else {
        require(
          at + 1 < reference.length(),
          "Native reference frame is truncated",
        )
        let value = reference[at].to_int() | (reference[at + 1].to_int() << 8)
        at += 2
        value
      }
      if sample != expected_sample {
        require(false, "Pixel mismatch frame=\{index}")
      }
    }
    count += plane.data.length().to_int64()
  }
  require(at == reference.length(), "Native reference frame byte count differs")
  count
}

///|
fn read_reference_frame(
  expected : ExpectedContainer,
  index : Int,
) -> Array[Byte] {
  require(
    index >= 0 && index < expected.frame_count,
    "Native reference frame index differs",
  )
  let data : Array[Byte] = []
  for _ in 0..<expected.frame_bytes {
    data.push(read_byte(1).to_byte())
  }
  if expected.schema_version == 2 {
    require(
      packet_crc32(data) == expected.frame_crc32[index],
      "Native reference frame CRC differs",
    )
  }
  data
}

///|
fn verify_reference_at(
  frame : @moonav1.Av1NativeFrame,
  index : Int,
  expected : ExpectedContainer,
) -> Int64 {
  require(
    io_seek(1, index.to_int64() * expected.frame_bytes.to_int64()) == 0,
    "Cannot seek native reference",
  )
  verify_native_frame(frame, index, expected)
}

///|
fn verify_demux(
  data : Array[Byte],
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
) -> Unit {
  let format = expected.format
  let track = match @moonav1.av1_demux(data, format=Some(format), limits~) {
    Err(error) => {
      require(false, "Demux failed: \{error.context}: \{error.message}")
      return
    }
    Ok(value) => value
  }
  verify_track(
    track.format,
    track.width,
    track.height,
    track.timescale,
    track.packets.length(),
    expected,
  )
  for index in 0..<track.packets.length() {
    verify_packet(track.packets[index], expected.packets[index])
  }
}

///|
fn verify_container_frame(
  value : @moonav1.Av1ContainerFrame,
  index : Int,
  expected : ExpectedContainer,
) -> Int64 {
  let packet_index = packet_for_presentation(index, expected)
  require(
    value.packet_index == packet_index,
    "Presentation packet index differs",
  )
  let packet = expected.packets[packet_index]
  assert_optional(
    value.timestamp,
    packet.pts,
    packet.flags,
    1,
    "Presentation PTS",
  )
  assert_optional(
    value.duration,
    packet.duration,
    packet.flags,
    4,
    "Presentation duration",
  )
  require(
    value.timescale == expected.timescale,
    "Presentation timescale differs",
  )
  verify_native_frame(
    value.frame,
    expected.native_frame_index_for_packet[packet_index],
    expected,
  )
}

///|
fn packet_for_presentation(index : Int, expected : ExpectedContainer) -> Int {
  require(index >= 0, "Negative presentation index")
  let mut presentation = 0
  for packet_index in 0..<expected.packet_count {
    let native_index = expected.native_frame_index_for_packet[packet_index]
    if native_index >= 0 {
      if presentation == index {
        return packet_index
      }
      presentation += 1
    }
  }
  require(false, "Presentation packet mapping is incomplete")
  0
}

///|
fn run_seek_checks(
  decoder : @moonav1.Av1ContainerDecoder,
  expected : ExpectedContainer,
) -> Unit {
  require(io_open(1) == 1, "Cannot open native reference for seeks")
  let indices = [0, expected.frame_count / 2, expected.frame_count - 1]
  for index in indices {
    let packet_index = packet_for_presentation(index, expected)
    let request = expected.packets[packet_index].pts
    let result = match decoder.seek_timestamp(request) {
      Err(error) => {
        require(false, "Seek failed: \{error.context}: \{error.message}")
        return
      }
      Ok(value) => value
    }
    require(result.outcome == @moonav1.Exact, "Seek outcome differs")
    let frame = match result.frame {
      Some(value) => value
      None => {
        require(false, "Exact seek returned no frame")
        return
      }
    }
    require(frame.packet_index == packet_index, "Seek packet index differs")
    require(frame.timestamp == Some(request), "Seek timestamp differs")
    assert_optional(
      frame.duration,
      expected.packets[packet_index].duration,
      expected.packets[packet_index].flags,
      4,
      "Seek duration",
    )
    require(frame.timescale == expected.timescale, "Seek timescale differs")
    ignore(
      verify_reference_at(
        frame.frame,
        expected.native_frame_index_for_packet[packet_index],
        expected,
      ),
    )
  }
  let last_packet = packet_for_presentation(expected.frame_count - 1, expected)
  let last = expected.packets[last_packet].pts
  let end = decoder.seek_timestamp(last + 1L).unwrap()
  require(end.outcome == @moonav1.End && end.frame is None, "Seek EOF differs")
  for packet_index in 0..<(expected.packet_count - 1) {
    let first = expected.packets[packet_index]
    let second = expected.packets[packet_index + 1]
    if (first.flags & 1) != 0 &&
      (second.flags & 1) != 0 &&
      expected.native_frame_index_for_packet[packet_index] >= 0 &&
      expected.native_frame_index_for_packet[packet_index + 1] >= 0 &&
      second.pts > first.pts + 1L {
      let between = decoder.seek_timestamp(first.pts + 1L).unwrap()
      require(
        between.outcome == @moonav1.Next,
        "Between-PTS seek outcome differs",
      )
      let frame = between.frame.unwrap()
      require(
        frame.packet_index == packet_index + 1,
        "Between-PTS seek selected wrong packet",
      )
      require(
        frame.timestamp == Some(second.pts),
        "Between-PTS seek timestamp differs",
      )
      assert_optional(
        frame.duration,
        second.duration,
        second.flags,
        4,
        "Between-PTS seek duration",
      )
      require(
        frame.timescale == expected.timescale,
        "Between-PTS seek timescale differs",
      )
      ignore(
        verify_reference_at(
          frame.frame,
          expected.native_frame_index_for_packet[packet_index + 1],
          expected,
        ),
      )
      break
    }
  }
  // A constant-frame-rate stream may have no integral gap; in that case the
  // exact/backward/end checks above remain the applicable seek coverage.
  // A backward seek must restore the reconstruction state and return the
  // exact earlier frame after the forward and end seeks above.
  let back_index = expected.frame_count / 4
  let back_packet = packet_for_presentation(back_index, expected)
  let back = decoder.seek_timestamp(expected.packets[back_packet].pts).unwrap()
  require(back.outcome == @moonav1.Exact, "Backward seek outcome differs")
  let back_frame = back.frame.unwrap()
  require(back_frame.packet_index == back_packet, "Backward seek index differs")
  require(
    back_frame.timestamp == Some(expected.packets[back_frame.packet_index].pts),
    "Backward seek timestamp differs",
  )
  ignore(
    verify_reference_at(
      back_frame.frame,
      expected.native_frame_index_for_packet[back_frame.packet_index],
      expected,
    ),
  )
  io_close(1)
}

///|
fn run_complete(
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
) -> Unit {
  let data = read_all_input()
  verify_demux(data, expected, limits)
  let format = expected.format
  let decoder = @moonav1.Av1ContainerDecoder::new(
    data,
    format=Some(format),
    limits~,
  ).unwrap()
  verify_track(
    decoder.format(),
    expected.declared_width,
    expected.declared_height,
    decoder.timescale(),
    decoder.packet_count(),
    expected,
  )
  require(io_open(1) == 1, "Cannot open native reference")
  let mut index = 0
  let mut samples : Int64 = 0L
  let mut first : @moonav1.Av1NativeFrame? = None
  while true {
    match decoder.next_frame() {
      Err(error) => {
        require(
          false,
          "Complete decode failed: \{error.context}: \{error.message}",
        )
        break
      }
      Ok(None) => break
      Ok(Some(value)) => {
        require(
          index < expected.frame_count,
          "Complete decoder returned too many frames",
        )
        samples += verify_container_frame(value, index, expected)
        if index == 0 {
          first = Some(value.frame)
        } else if index == 1 {
          first.unwrap().planes[0].data[0] = -1
          require(
            value.frame.planes[0].data[0] >= 0,
            "Returned frame ownership aliases",
          )
        }
        index += 1
      }
    }
  }
  require(index == expected.frame_count, "Complete presentation count differs")
  require(io_read(1) == -1, "Native reference has unexpected trailing bytes")
  io_close(1)
  decoder.reset()
  require(io_open(1) == 1, "Cannot reopen native reference")
  let reset_frame = decoder.next_frame().unwrap().unwrap()
  let reset_packet = packet_for_presentation(0, expected)
  require(
    reset_frame.packet_index == reset_packet,
    "Decoder reset position differs",
  )
  ignore(
    verify_native_frame(
      reset_frame.frame,
      expected.native_frame_index_for_packet[reset_packet],
      expected,
    ),
  )
  io_close(1)
  run_seek_checks(decoder, expected)
  println(
    "RESULT mode=complete frames=\{index} samples=\{samples} peak_pending=0 cap=0 pre_eof=true replay=false reset=true",
  )
}

///|
fn read_chunk(size : Int) -> (Array[Byte], Bool) {
  let chunk : Array[Byte] = []
  let mut eof = false
  for _ in 0..<size {
    let value = io_read(0)
    if value == -1 {
      eof = true
      break
    }
    require(value >= 0, "Container input read failed")
    chunk.push(value.to_byte())
  }
  (chunk, eof)
}

///|
/// Simulate reusing a host read buffer immediately after feed returns.
fn overwrite_chunk(chunk : Array[Byte]) -> Unit {
  for i in 0..<chunk.length() {
    chunk[i] = 255
  }
}

///|
fn check_metadata_ownership(
  get_info : () -> @moonav1.Av1ContainerStreamInfo?,
) -> Bool {
  let info = match get_info() {
    None => return false
    Some(value) => value
  }
  let initialization = info.codec_initialization.copy()
  let edits = info.edits.map(edit => {
    (edit.duration, edit.media_time, edit.media_rate)
  })
  if !info.codec_initialization.is_empty() {
    info.codec_initialization[0] = 255
  }
  info.codec_initialization.push(255)
  info.edits.clear()
  let next = get_info().unwrap()
  require(
    next.codec_initialization == initialization,
    "Returned codec initialization aliases parser metadata",
  )
  require(
    next.edits.map(edit => (edit.duration, edit.media_time, edit.media_rate)) ==
    edits,
    "Returned edit list aliases parser metadata",
  )
  true
}

///|
fn exercise_failed_input(decoder : @moonav1.Av1ContainerStreamDecoder) -> Unit {
  require(io_open(0) == 0, "Cannot open input for interrupted read")
  let prefix = [read_byte(0).to_byte()]
  io_close(0)
  let partial = decoder.feed(prefix).unwrap()
  require(
    partial.status == @moonav1.NeedMoreInput && partial.frames.is_empty(),
    "One-byte prefix unexpectedly produced output",
  )
  let failure = match decoder.finish() {
    Err(error) => error
    Ok(_) => abort("Interrupted read unexpectedly completed")
  }
  require(
    failure.kind == @moonav1.TruncatedInput,
    "Wrong interrupted-read error",
  )
  require(
    decoder.feed([]) is Err(error) && error == failure,
    "Feed did not retain the parser failure",
  )
  require(
    decoder.finish() is Err(error) && error == failure,
    "Finish did not retain the parser failure",
  )
  require(
    decoder.replay() is Err(error) && error == failure,
    "Replay did not retain the parser failure",
  )
  decoder.reset()
  require(decoder.track_info() is None, "Reset retained track metadata")
  require(
    decoder.pending_bytes() == 0 && decoder.peak_pending_bytes() == 0,
    "Reset retained input accounting",
  )
}

///|
fn verify_stream_info(
  decoder : @moonav1.Av1ContainerStreamDecoder,
  expected : ExpectedContainer,
) -> Unit {
  let info = match decoder.track_info() {
    Some(value) => value
    None => {
      require(false, "Stream produced packets without track metadata")
      return
    }
  }
  require(info.format == expected.format, "Stream container format differs")
  require(
    info.width == expected.declared_width &&
    info.height == expected.declared_height,
    "Stream track geometry differs",
  )
  require(
    info.timescale == expected.timescale,
    "Stream track timescale differs",
  )
}

///|
struct PacketStreamState {
  mut index : Int
  mut first : @moonav1.Av1Packet?
}

///|
struct PacketPass {
  packets : Int
  peak_pending : Int
  terminal : @moonav1.Av1ContainerStreamStatus
}

///|
fn consume_stream_packets(
  state : PacketStreamState,
  packets : Array[@moonav1.Av1Packet],
  expected : ExpectedContainer,
) -> Unit {
  for packet in packets {
    require(
      state.index < expected.packet_count,
      "Stream emitted too many packets",
    )
    verify_packet(packet, expected.packets[state.index])
    if state.index == 0 {
      state.first = Some(packet)
    } else if state.index == 1 {
      let retained = packet.data[0]
      let changed = (state.first.unwrap().data[0].to_int() ^ 255).to_byte()
      state.first.unwrap().data[0] = changed
      require(packet.data[0] == retained, "Stream packet ownership aliases")
    }
    state.index += 1
  }
}

///|
fn packet_stream_pass(
  stream : @moonav1.Av1ContainerStream,
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
) -> PacketPass {
  require(io_open(0) == 0, "Cannot open packet-stream input")
  let chunk_sizes = expected.chunk_sizes
  let mut chunk_index = 0
  let state : PacketStreamState = { index: 0, first: None, }
  let mut peak = 0
  let mut received = 0L
  let mut metadata_checked = false
  let mut terminal = @moonav1.Av1ContainerStreamStatus::NeedMoreInput
  while true {
    let idle = stream.feed([]).unwrap()
    require(
      idle.status == @moonav1.NeedMoreInput && idle.packets.is_empty(),
      "Empty feed changed packet stream lifecycle",
    )
    let (chunk, eof) = read_chunk(
      chunk_sizes[chunk_index % chunk_sizes.length()],
    )
    chunk_index += 1
    let batch = if eof && chunk.is_empty() {
      stream.finish().unwrap()
    } else {
      stream.feed(chunk).unwrap()
    }
    received += chunk.length().to_int64()
    overwrite_chunk(chunk)
    if !metadata_checked {
      metadata_checked = check_metadata_ownership(fn() { stream.track_info() })
    }
    if eof && chunk.is_empty() {
      require(
        batch.status == @moonav1.Finished ||
        batch.status == @moonav1.ReplayRequired,
        "Packet stream failed to terminate at EOF",
      )
    }
    consume_stream_packets(state, batch.packets, expected)
    let pending = stream.pending_bytes()
    if pending > peak {
      peak = pending
    }
    require(
      pending <= limits.max_input_bytes,
      "Packet stream pending bytes exceed selected cap",
    )
    require(
      stream.peak_pending_bytes() <= limits.max_input_bytes,
      "Packet stream peak pending bytes exceed selected cap",
    )
    if stream.peak_pending_bytes() > peak {
      peak = stream.peak_pending_bytes()
    }
    terminal = batch.status
    if terminal == @moonav1.Av1ContainerStreamStatus::Finished ||
      terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired {
      break
    }
  }
  require(metadata_checked, "Packet stream never exposed track metadata")
  require(
    stream.bytes_received() == received,
    "Packet stream byte count differs",
  )
  let ended = stream.finish().unwrap()
  require(
    ended.status == terminal && ended.packets.is_empty(),
    "Repeated finish duplicated packets or changed status",
  )
  io_close(0)
  { packets: state.index, peak_pending: peak, terminal, }
}

///|
fn verify_stream_packets(
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
  replay_required : Bool,
) -> Unit {
  let stream = @moonav1.Av1ContainerStream::new(limits~).unwrap()
  let first = packet_stream_pass(stream, expected, limits)
  let mut peak = first.peak_pending
  if replay_required {
    require(
      first.terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired,
      "Packet stream tail did not request replay",
    )
    require(first.packets == 0, "Packet stream emitted packets before replay")
    stream.replay().unwrap()
    let replay = packet_stream_pass(stream, expected, limits)
    require(
      replay.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Packet stream replay did not finish",
    )
    require(
      replay.packets == expected.packet_count,
      "Packet stream replay packet count differs",
    )
    if replay.peak_pending > peak {
      peak = replay.peak_pending
    }
  } else {
    require(
      first.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Packet stream did not finish",
    )
    require(
      first.packets == expected.packet_count,
      "Packet stream packet count differs",
    )
  }
  require(
    peak <= limits.max_input_bytes,
    "Packet stream peak exceeds selected cap",
  )
  stream.reset()
  let reset = packet_stream_pass(stream, expected, limits)
  if replay_required {
    require(
      reset.terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired,
      "Packet stream reset replay status differs",
    )
    require(
      reset.packets == 0,
      "Packet stream reset emitted packets before replay",
    )
    stream.replay().unwrap()
    let reset_replay = packet_stream_pass(stream, expected, limits)
    require(
      reset_replay.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Packet stream reset replay did not finish",
    )
    require(
      reset_replay.packets == expected.packet_count,
      "Packet stream reset packet count differs",
    )
  } else {
    require(
      reset.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Packet stream reset status differs",
    )
    require(
      reset.packets == expected.packet_count,
      "Packet stream reset packet count differs",
    )
  }
}

///|
fn stream_pass(
  decoder : @moonav1.Av1ContainerStreamDecoder,
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
  pixels : Bool,
) -> StreamRun {
  require(io_open(0) == 0, "Cannot open streaming input")
  require(io_open(1) == 1, "Cannot open streaming native reference")
  let chunk_sizes = expected.chunk_sizes
  let mut chunk_index = 0
  let mut frame_index = 0
  let mut samples : Int64 = 0L
  let mut peak = 0
  let mut pre_eof = false
  let mut terminal = @moonav1.Av1ContainerStreamStatus::NeedMoreInput
  let mut first : @moonav1.Av1NativeFrame? = None
  let mut metadata_checked = false
  while true {
    let idle = decoder.feed([]).unwrap()
    require(
      idle.status == @moonav1.NeedMoreInput && idle.frames.is_empty(),
      "Empty feed changed decoder lifecycle",
    )
    let (chunk, eof) = read_chunk(
      chunk_sizes[chunk_index % chunk_sizes.length()],
    )
    chunk_index += 1
    let finishing = eof && chunk.is_empty()
    let batch = if finishing {
      decoder.finish().unwrap()
    } else {
      decoder.feed(chunk).unwrap()
    }
    overwrite_chunk(chunk)
    if !metadata_checked {
      metadata_checked = check_metadata_ownership(fn() { decoder.track_info() })
    }
    if eof && chunk.is_empty() {
      require(
        batch.status == @moonav1.Finished ||
        batch.status == @moonav1.ReplayRequired,
        "Decoder stream failed to terminate at EOF",
      )
    }
    // A short final read already observes host EOF, but its nonempty bytes
    // are still a feed. The API receives the EOF signal only through finish.
    if batch.frames.length() > 0 && !finishing {
      pre_eof = true
    }
    for value in batch.frames {
      require(pixels, "Stream emitted pixels during metadata-only pass")
      require(
        frame_index < expected.frame_count,
        "Stream decoder returned too many frames",
      )
      samples += verify_container_frame(value, frame_index, expected)
      if frame_index == 0 {
        first = Some(value.frame)
      } else if frame_index == 1 {
        first.unwrap().planes[0].data[0] = -1
        require(
          value.frame.planes[0].data[0] >= 0,
          "Stream frame ownership aliases",
        )
      }
      frame_index += 1
    }
    let pending = decoder.pending_bytes()
    if pending > peak {
      peak = pending
    }
    require(
      pending <= limits.max_input_bytes,
      "Stream pending bytes exceed selected cap",
    )
    require(
      decoder.peak_pending_bytes() <= limits.max_input_bytes,
      "Stream peak pending bytes exceed selected cap",
    )
    if decoder.peak_pending_bytes() > peak {
      peak = decoder.peak_pending_bytes()
    }
    terminal = batch.status
    if terminal == @moonav1.Av1ContainerStreamStatus::Finished ||
      terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired {
      break
    }
  }
  require(metadata_checked, "Decoder never exposed track metadata")
  let ended = decoder.finish().unwrap()
  require(
    ended.status == terminal && ended.frames.is_empty(),
    "Repeated finish duplicated frames or changed status",
  )
  require(
    io_read(1) == -1 || !pixels,
    "Native reference has unexpected trailing bytes",
  )
  io_close(0)
  io_close(1)
  if pixels {
    require(
      frame_index == expected.frame_count,
      "Stream presentation count differs",
    )
  } else {
    require(frame_index == 0, "Metadata-only stream emitted frames")
  }
  require(
    terminal == @moonav1.Av1ContainerStreamStatus::Finished ||
    terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired,
    "Stream terminal status differs",
  )
  { frames: frame_index, samples, peak_pending: peak, pre_eof, terminal, }
}

///|
fn run_stream(
  expected : ExpectedContainer,
  limits : @moonav1.DecodeLimits,
  replay_required : Bool,
) -> Unit {
  verify_stream_packets(expected, limits, replay_required)
  let decoder = @moonav1.Av1ContainerStreamDecoder::new(limits~).unwrap()
  // The complete pixel pass below must recover on the same decoder after a
  // truncated input has made its error sticky.
  exercise_failed_input(decoder)
  let first_pass = stream_pass(decoder, expected, limits, !replay_required)
  let mut peak = first_pass.peak_pending
  let mut replayed = false
  let mut replayed_samples : Int64 = 0L
  if replay_required {
    require(
      first_pass.terminal == @moonav1.Av1ContainerStreamStatus::ReplayRequired,
      "Tail MP4 did not request replay",
    )
    require(
      first_pass.frames == 0 && !first_pass.pre_eof,
      "Tail MP4 emitted before replay",
    )
    verify_stream_info(decoder, expected)
    decoder.replay().unwrap()
    replayed = true
    let replay_pass = stream_pass(decoder, expected, limits, true)
    require(
      replay_pass.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Replay did not finish",
    )
    require(replay_pass.pre_eof, "Replay emitted no frames before EOF")
    replayed_samples = replay_pass.samples
    if replay_pass.peak_pending > peak {
      peak = replay_pass.peak_pending
    }
  } else {
    require(
      first_pass.terminal == @moonav1.Av1ContainerStreamStatus::Finished,
      "Stream did not finish",
    )
    require(
      first_pass.pre_eof,
      "Metadata-first stream produced no pre-EOF frames",
    )
    verify_stream_info(decoder, expected)
  }
  decoder.reset()
  // Reopening and decoding a prefix proves reset clears the parser and AV1
  // reconstruction state without retaining the previous stream's handles.
  require(io_open(0) == 0, "Cannot reopen input after reset")
  require(io_open(1) == 1, "Cannot reopen reference after reset")
  let mut checked = false
  let mut reset_replayed = false
  while !checked {
    let (chunk, eof) = read_chunk(
      expected.chunk_sizes[expected.chunk_sizes.length() - 1],
    )
    let batch = if eof && chunk.is_empty() {
      decoder.finish().unwrap()
    } else {
      decoder.feed(chunk).unwrap()
    }
    for value in batch.frames {
      let reset_packet = packet_for_presentation(0, expected)
      require(
        value.packet_index == reset_packet,
        "Reset prefix packet index differs",
      )
      ignore(
        verify_native_frame(
          value.frame,
          expected.native_frame_index_for_packet[reset_packet],
          expected,
        ),
      )
      checked = true
      break
    }
    if batch.status == @moonav1.Av1ContainerStreamStatus::ReplayRequired {
      require(!reset_replayed, "Reset replay requested more than once")
      reset_replayed = true
      io_close(0)
      io_close(1)
      decoder.replay().unwrap()
      require(io_open(0) == 0, "Cannot reopen input for reset replay")
      require(io_open(1) == 1, "Cannot reopen reference for reset replay")
    } else if batch.status == @moonav1.Av1ContainerStreamStatus::Finished {
      break
    } else if eof && chunk.is_empty() {
      abort("Reset stream failed to terminate at EOF")
    }
  }
  require(checked, "Reset did not produce the first frame")
  io_close(0)
  io_close(1)
  // Cancel an unfinished restarted decode and verify a second failure/reset
  // cycle after the instance has held live AV1 references.
  decoder.reset()
  exercise_failed_input(decoder)
  let samples = if replay_required {
    replayed_samples
  } else {
    first_pass.samples
  }
  println(
    "RESULT mode=stream frames=\{expected.frame_count} samples=\{samples} peak_pending=\{peak} cap=\{limits.max_input_bytes} pre_eof=true replay=\{replayed} reset=true input_reuse=true recovery=true metadata_owned=true auto_format=true",
  )
}

///|
fn main {
  let expected = read_expectation()
  if io_config(4) == 1 {
    match @moonav1.av1_demux(read_all_input(kind=3)) {
      Err(error) =>
        require(
          error.kind == @moonav1.InvalidData &&
          error.context == "mp4" &&
          error.message == "av01 dimensions exceed the av1C sequence header",
          "Original AMF MP4 returned a different error",
        )
      Ok(_) =>
        abort("Original AMF MP4 unexpectedly accepted inconsistent dimensions")
    }
    println("REJECTED original_error=InvalidData")
  }
  let mode = io_config(0)
  let cap = io_config(1)
  let max_frames = io_config(2)
  let configured_total_pixels = io_config(3)
  require(
    mode >= 0 && cap > 0 && max_frames > expected.frame_count,
    "Run through scripts/check-long-containers.py",
  )
  let max_total_pixels = if configured_total_pixels > 0 {
    configured_total_pixels
  } else {
    expected.max_total_pixels
  }
  let limits : @moonav1.DecodeLimits = {
    max_input_bytes: cap,
    max_frame_pixels: 16 * 1024 * 1024,
    max_total_pixels,
    max_frames,
  }
  if mode == 0 {
    run_complete(expected, limits)
  } else {
    run_stream(expected, limits, mode == 2)
  }
}
