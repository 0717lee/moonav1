///|
fn demux_test_le(
  bytes : Array[Byte],
  at : Int,
  count : Int,
  value : Int64,
) -> Unit {
  for i in 0..<count {
    bytes[at + i] = ((value >> (8 * i)) & 255L).to_int().to_byte()
  }
}

///|
fn demux_test_ivf(
  packets : Array[(Int64, Array[Byte])],
  rate? : Int64 = 30000L,
  scale? : Int64 = 1001L,
  count? : Int64? = None,
) -> Array[Byte] {
  let data = Array::make(32, b'\x00')
  data[0] = b'D'
  data[1] = b'K'
  data[2] = b'I'
  data[3] = b'F'
  demux_test_le(data, 6, 2, 32L)
  data[8] = b'A'
  data[9] = b'V'
  data[10] = b'0'
  data[11] = b'1'
  demux_test_le(data, 12, 2, 64L)
  demux_test_le(data, 14, 2, 32L)
  demux_test_le(data, 16, 4, rate)
  demux_test_le(data, 20, 4, scale)
  let declared = match count {
    Some(value) => value
    None => packets.length().to_int64()
  }
  demux_test_le(data, 24, 4, declared)
  for packet in packets {
    let (timestamp, payload) = packet
    let at = data.length()
    for _ in 0..<12 {
      data.push(0)
    }
    demux_test_le(data, at, 4, payload.length().to_int64())
    demux_test_le(data, at + 4, 8, timestamp)
    for byte in payload {
      data.push(byte)
    }
  }
  data
}

///|
fn[T] demux_test_error(
  result : Result[T, DecodeError],
) -> DecodeErrorKind raise {
  match result {
    Err(error) => error.kind
    Ok(_) => fail("Malformed container unexpectedly accepted")
  }
}

///|
test "IVF keeps wide signed timestamps and exact time base in record order" {
  let input = demux_test_ivf([(4294967298L, [1, 2, 3]), (-5L, [4, 5])])
  let track = av1_demux_ivf(input).unwrap()
  assert_eq(track.format, Ivf)
  assert_eq((track.width, track.height, track.timescale), (64, 32, 30000L))
  assert_eq(track.packets.length(), 2)
  assert_eq(track.packets[0].presentation_timestamp, Some(4299262265298L))
  assert_eq(track.packets[1].presentation_timestamp, Some(-5005L))
  for packet in track.packets {
    assert_eq(packet.decode_timestamp, None)
    assert_eq(packet.duration, None)
    assert_eq(packet.sync_sample, None)
  }
  input[44] = 99
  assert_eq(track.packets[0].data, [1, 2, 3])
  track.packets[0].data[0] = 42
  assert_eq(track.packets[1].data, [4, 5])
}

///|
test "IVF truncated headers payloads and missing declared records are distinct" {
  let complete = demux_test_ivf([(0L, [1, 2]), (1L, [3, 4])])
  for cut in 0..<32 {
    assert_eq(
      demux_test_error(av1_demux_ivf(Array::makei(cut, i => complete[i]))),
      TruncatedInput,
    )
  }
  for cut in [33, 43, 45, 46, complete.length() - 1] {
    assert_eq(
      demux_test_error(av1_demux_ivf(Array::makei(cut, i => complete[i]))),
      TruncatedInput,
    )
  }
  let enormous = complete.copy()
  demux_test_le(enormous, 32, 4, 4294967295L)
  assert_eq(demux_test_error(av1_demux_ivf(enormous)), TruncatedInput)
  assert_eq(
    demux_test_error(av1_demux_ivf(demux_test_ivf([(0L, [])]))),
    InvalidData,
  )
  assert_eq(
    demux_test_error(
      av1_demux_ivf(demux_test_ivf([(0L, [1]), (1L, [2])], count=Some(1L))),
    ),
    InvalidData,
  )
}

///|
test "IVF metadata and selected work limits reject before unsafe arithmetic" {
  let complete = demux_test_ivf([(0L, [1]), (1L, [2])], count=Some(0L))
  assert_eq(av1_demux_ivf(complete).unwrap().packets.length(), 2)
  assert_eq(
    demux_test_error(
      av1_demux_ivf(complete, limits={
        ..DecodeLimits::default(),
        max_frames: 1,
      }),
    ),
    LimitExceeded,
  )
  assert_eq(
    demux_test_error(
      av1_demux_ivf(complete, limits={
        ..DecodeLimits::default(),
        max_input_bytes: 31,
      }),
    ),
    LimitExceeded,
  )
  assert_eq(
    demux_test_error(
      av1_demux_ivf(complete, limits={
        ..DecodeLimits::default(),
        max_frames: 0,
      }),
    ),
    InvalidData,
  )
  let dimensions = complete.copy()
  demux_test_le(dimensions, 12, 2, 65535L)
  demux_test_le(dimensions, 14, 2, 65535L)
  assert_eq(demux_test_error(av1_demux_ivf(dimensions)), LimitExceeded)
  for field in [12, 14, 16, 20] {
    let bad = complete.copy()
    demux_test_le(bad, field, if field < 16 { 2 } else { 4 }, 0L)
    assert_eq(demux_test_error(av1_demux_ivf(bad)), InvalidData)
  }
  let codec = complete.copy()
  codec[10] = b'8'
  assert_eq(demux_test_error(av1_demux_ivf(codec)), Unsupported)
  let version = complete.copy()
  version[4] = 1
  assert_eq(demux_test_error(av1_demux_ivf(version)), Unsupported)
  assert_true(av1_demux_ivf(demux_test_ivf([])).unwrap().packets.is_empty())
}

///|
test "IVF extended headers and Int64 boundary timestamps are supported" {
  let min = -9223372036854775807L - 1L
  let max = 9223372036854775807L
  let complete = demux_test_ivf(
    [(min, [1]), (max, [2])],
    rate=4294967295L,
    scale=1L,
  )
  let extended = Array::makei(complete.length() + 4, i => {
    if i < 32 {
      complete[i]
    } else if i < 36 {
      b'\xEE'
    } else {
      complete[i - 4]
    }
  })
  demux_test_le(extended, 6, 2, 36L)
  let track = av1_demux_ivf(extended).unwrap()
  assert_eq(track.timescale, 4294967295L)
  assert_eq(track.packets[0].presentation_timestamp, Some(min))
  assert_eq(track.packets[1].presentation_timestamp, Some(max))
  for value in [min, max] {
    assert_eq(
      demux_test_error(av1_demux_ivf(demux_test_ivf([(value, [1])], scale=2L))),
      Unsupported,
    )
  }
}

///|
test "av1C rejects inconsistent colors reserved bits and noninitial sequence" {
  let config : Array[Byte] = [0x81, 0, 0x0C, 0]
  let sequence : Array[Byte] = [0x0A, 0x06, 0x18, 0x15, 0x7F, 0xFC, 0, 8]
  let full = config.copy()
  for byte in sequence {
    full.push(byte)
  }
  assert_eq(av1_demux_av1c(config).unwrap(), [])
  assert_eq(av1_demux_av1c(full).unwrap(), sequence)
  let level_mismatch = full.copy()
  level_mismatch[1] = 1
  assert_eq(demux_test_error(av1_demux_av1c(level_mismatch)), InvalidData)
  let position_mismatch = full.copy()
  position_mismatch[2] = 0x0D
  assert_eq(demux_test_error(av1_demux_av1c(position_mismatch)), InvalidData)
  let mismatched = full.copy()
  mismatched[2] = 0x4C
  assert_eq(demux_test_error(av1_demux_av1c(mismatched)), InvalidData)
  let repeated = full.copy()
  for byte in sequence {
    repeated.push(byte)
  }
  assert_eq(demux_test_error(av1_demux_av1c(repeated)), InvalidData)
  let frame_obu = config.copy()
  frame_obu.push(0x32)
  frame_obu.push(0)
  assert_eq(demux_test_error(av1_demux_av1c(frame_obu)), InvalidData)
  for invalid_flags in [0x0F, 0x2C, 0x04, 0x08] {
    let bad = config.copy()
    bad[2] = invalid_flags.to_byte()
    assert_eq(demux_test_error(av1_demux_av1c(bad)), InvalidData)
  }
  for delay in [1, 0x20] {
    let bad = config.copy()
    bad[3] = delay.to_byte()
    assert_eq(demux_test_error(av1_demux_av1c(bad)), InvalidData)
  }
}

///|
test "container cursor defers payload errors and keeps failure sticky until reset" {
  // IVF framing is valid; its one OBU header is deliberately incomplete.
  let input = demux_test_ivf([(0L, [0x0A])])
  let cursor = Av1ContainerDecoder::new(input).unwrap()
  assert_eq(cursor.packet_count(), 1)
  assert_eq(cursor.position(), 0)
  assert_eq(cursor.format(), Ivf)
  assert_eq(cursor.timescale(), 30000L)
  let first = match cursor.next_frame() {
    Err(error) => error
    Ok(_) => fail("Invalid AV1 payload was accepted")
  }
  assert_eq(first.kind, TruncatedInput)
  assert_eq(first.byte_offset, None)
  assert_eq(cursor.position(), 0)
  match cursor.next_frame() {
    Err(error) => assert_eq(error, first)
    Ok(_) => fail("Payload failure was not sticky")
  }
  cursor.reset()
  assert_eq(cursor.position(), 0)
  assert_eq(demux_test_error(cursor.next_frame()), TruncatedInput)
  let empty = Av1ContainerDecoder::new(demux_test_ivf([])).unwrap()
  assert_true(empty.next_frame().unwrap() is None)
  assert_true(empty.next_frame().unwrap() is None)
}

///|
test "AV1 UVLC skips leading zeros and consumes the full codeword" {
  for example in [([0x80], 1), ([0x40], 3), ([0x20], 5)] {
    let data : Array[Byte] = example.0.map(x => x.to_byte())
    let reader = Av1BitReader::new(data)
    assert_true(av1_skip_uvlc(reader))
    assert_eq(reader.bit_pos, example.1)
  }
  assert_false(av1_skip_uvlc(Av1BitReader::new([0, 0, 0, 0])))
  assert_false(av1_skip_uvlc(Av1BitReader::new([0x08])))
  let sentinel = Av1BitReader::new([0, 0, 0, 0, 0x80])
  assert_true(av1_skip_uvlc(sentinel))
  assert_eq(sentinel.bit_pos, 33)
}
